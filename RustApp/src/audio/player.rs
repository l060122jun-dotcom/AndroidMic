use anyhow::bail;
use cpal::traits::DeviceTrait;
use rtrb::{Consumer, chunks::ChunkError};

use crate::config::{AudioFormat, ChannelCount, SampleRate};

use super::{AudioBytes, AudioPacketFormat};

pub fn create_audio_stream(
    device: &cpal::Device,
    config: AudioPacketFormat,
    consumer: Consumer<u8>,
) -> anyhow::Result<(cpal::Stream, AudioPacketFormat)> {
    let audio_format = config.audio_format.clone();
    let sample_rate = config.sample_rate.to_number();
    let mut channel_count = config.channel_count.to_number();

    // check if config is supported by device
    let supported_configs = device.supported_output_configs()?;

    let mut matched_config = None;
    for supported_config in supported_configs {
        if audio_format == supported_config.sample_format()
            && supported_config.max_sample_rate() >= sample_rate
            && supported_config.min_sample_rate() <= sample_rate
        {
            // use recommended channel count
            if supported_config.channels() != channel_count {
                warn!(
                    "Using channel count {} instead of {}",
                    supported_config.channels(),
                    channel_count
                );
                channel_count = supported_config.channels();
            }
            matched_config = Some(supported_config);
            break;
        }
    }

    let Some(matched_config) = matched_config else {
        bail!(
            "Unsupported output audio format or sample rate. Please apply recommended format from settings page."
        );
    };

    let config = cpal::StreamConfig {
        channels: channel_count,
        sample_rate,
        buffer_size: preferred_buffer_size(&matched_config),
    };

    // create stream config
    let stream: cpal::Stream = match audio_format {
        AudioFormat::I16 => build_output_stream::<i16>(device, config, consumer),
        AudioFormat::I24 => build_output_stream::<f32>(device, config, consumer),
        AudioFormat::I32 => build_output_stream::<i32>(device, config, consumer),
        AudioFormat::U8 => build_output_stream::<u8>(device, config, consumer),
        AudioFormat::F32 => build_output_stream::<f32>(device, config, consumer),
    }?;

    // convert stream config to AudioPacketFormat
    let config = AudioPacketFormat {
        sample_rate: SampleRate::from_number(sample_rate).unwrap(),
        audio_format,
        channel_count: ChannelCount::from_number(channel_count).unwrap(),
    };

    Ok((stream, config))
}

/// Target size of the cpal output callback buffer, in frames.
///
/// Request 128 frames (~2.7 ms at 48 kHz), clamped to the reported range.
/// Backend buffering and scheduling still affect latency and underrun risk;
/// being inside the supported range is not a real-time performance guarantee.
const PREFERRED_FRAMES: u32 = 128;

fn preferred_buffer_size(supported_config: &cpal::SupportedStreamConfigRange) -> cpal::BufferSize {
    if let cpal::SupportedBufferSize::Range { min, max } = supported_config.buffer_size() {
        return cpal::BufferSize::Fixed(PREFERRED_FRAMES.clamp(*min, *max));
    }

    cpal::BufferSize::Default
}

pub fn process_audio<F>(data: &mut [F], consumer: &mut Consumer<u8>, frame_bytes: usize)
where
    F: cpal::SizedSample + AudioBytes,
{
    data.fill(F::from_f32(0.0));

    let frame_size = std::mem::size_of::<F>();

    let byte_len = std::mem::size_of_val(data);

    let chunk = match consumer.read_chunk(byte_len) {
        Ok(c) => c,
        Err(ChunkError::TooFewSlots(slots)) if slots > 0 => {
            let aligned = slots - (slots % frame_bytes);
            match consumer.read_chunk(aligned) {
                Ok(c) => c,
                Err(_) => return,
            }
        }
        _ => return,
    };

    let (chunk1, mut chunk2) = chunk.as_slices();

    let chunk1_iter = chunk1.chunks_exact(frame_size);

    // handle case if a frame is split in chunk1 and chunk2.
    // this will probably never happens tho
    let mid_part = if !chunk1_iter.remainder().is_empty() {
        let (right_part, chunk2_) = chunk2.split_at(frame_size - chunk1_iter.remainder().len());

        chunk2 = chunk2_;

        let mut v = Vec::with_capacity(frame_size);

        v.extend(chunk1_iter.remainder());
        v.extend(right_part);

        itertools::Either::Left(std::iter::once(F::from_bytes(&v)))
    } else {
        itertools::Either::Right(std::iter::empty())
    };

    let samples = chunk1_iter
        .map(|b| F::from_bytes(b))
        .chain(mid_part)
        .chain(chunk2.chunks_exact(frame_size).map(|b| F::from_bytes(b)));

    for (out, sample) in data.iter_mut().zip(samples) {
        *out = sample;
    }

    chunk.commit_all();
}

fn build_output_stream<F>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    mut consumer: Consumer<u8>,
) -> anyhow::Result<cpal::Stream, cpal::Error>
where
    F: cpal::SizedSample + AudioBytes + 'static,
{
    let frame_size = std::mem::size_of::<F>();
    let channels = config.channels as usize;
    let frame_bytes = frame_size * channels;
    // Keep fresh audio after a scheduling stall instead of playing up to the
    // full ring capacity of stale speech. Only the consumer advances its head.
    let backlog_limit = (config.sample_rate as usize / 50).max(1) * frame_bytes;

    device.build_output_stream(
        config,
        move |data: &mut [F], _| {
            trim_stale_audio(&mut consumer, backlog_limit, frame_bytes);
            process_audio(data, &mut consumer, frame_bytes);
        },
        |err| error!("an error occurred on audio stream: {err}"),
        None,
    )
}

fn trim_stale_audio(consumer: &mut Consumer<u8>, limit: usize, frame_bytes: usize) {
    if frame_bytes == 0 {
        return;
    }
    let excess = consumer.slots().saturating_sub(limit);
    let discard = excess - excess % frame_bytes;
    if discard > 0 {
        if let Ok(chunk) = consumer.read_chunk(discard) {
            chunk.commit_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use rtrb::RingBuffer;

    use super::*;

    fn i16_samples_to_bytes(samples: &[i16]) -> Vec<u8> {
        samples.iter().flat_map(AudioBytes::to_bytes).collect()
    }

    #[test]
    fn process_audio_silences_output_when_buffer_is_empty() {
        let (_producer, mut consumer) = RingBuffer::<u8>::new(16);
        let mut output = [123_i16, -456, 789, -111];

        process_audio(&mut output, &mut consumer, std::mem::size_of::<i16>());

        assert_eq!(output, [0; 4]);
    }

    #[test]
    fn process_audio_zero_fills_after_partial_read() {
        let (mut producer, mut consumer) = RingBuffer::<u8>::new(16);
        let input = i16_samples_to_bytes(&[1000, -2000]);
        producer.write_all(&input).unwrap();

        let mut output = [55_i16, 55, 55, 55];
        process_audio(&mut output, &mut consumer, std::mem::size_of::<i16>());

        assert_eq!(output, [1000, -2000, 0, 0]);
    }

    #[test]
    fn backlog_trim_keeps_newest_complete_frames() {
        let (mut producer, mut consumer) = RingBuffer::<u8>::new(32);
        producer
            .write_all(&i16_samples_to_bytes(&[1, 2, 3, 4, 5, 6]))
            .unwrap();
        trim_stale_audio(&mut consumer, 8, 4);
        let mut output = [0_i16; 4];
        process_audio(&mut output, &mut consumer, 4);
        assert_eq!(output, [3, 4, 5, 6]);
    }
}
