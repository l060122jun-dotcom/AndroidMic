package io.github.teamclouday.androidMic.ui.home

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.ui.res.stringResource
import io.github.teamclouday.androidMic.R
import io.github.teamclouday.androidMic.ui.MainViewModel
import io.github.teamclouday.androidMic.ui.components.ManagerButton
import io.github.teamclouday.androidMic.ui.home.dialog.BaseDialog

fun getWifiPermission(): MutableList<String> {
    val list = mutableListOf<String>()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        list.add(Manifest.permission.POST_NOTIFICATIONS)

    return list
}

fun getBluetoothPermission(): MutableList<String> {
    val list = mutableListOf<String>()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        list.add(Manifest.permission.POST_NOTIFICATIONS)

    list.add(Manifest.permission.BLUETOOTH)

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        list.add(Manifest.permission.BLUETOOTH_CONNECT)

    return list
}

fun getUsbPermission(): MutableList<String> {
    val list = mutableListOf<String>()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        list.add(Manifest.permission.POST_NOTIFICATIONS)

    return list
}

fun getRecordAudioPermission(): MutableList<String> {
    val list = mutableListOf<String>()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        list.add(Manifest.permission.POST_NOTIFICATIONS)

    list.add(Manifest.permission.RECORD_AUDIO)

    return list
}

fun Activity.openAppSettings() {
    Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.fromParts("package", packageName, null)
    ).also(::startActivity)
}

@Composable
fun PermissionDialog(
    vm: MainViewModel,
    expanded: MutableState<Boolean>,
    onRequestPermissionAgain: () -> Unit,
    openAppSettings: () -> Unit
) {

    BaseDialog(
        expanded
    ) {

        Text(stringResource(id = R.string.permission_rationale))

        ManagerButton(
            text = stringResource(id = R.string.permission_request_again),
            onClick = {
                onRequestPermissionAgain()
                expanded.value = false
            }
        )

        ManagerButton(
            text = stringResource(id = R.string.permission_allow_manually),
            onClick = {
                openAppSettings()
                expanded.value = false
            }
        )

    }
}