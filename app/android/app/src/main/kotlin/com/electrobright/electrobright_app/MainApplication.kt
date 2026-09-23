package com.electrobright.electrobright_app

import android.app.Application
import com.polidea.rxandroidble2.exceptions.BleException
import io.reactivex.exceptions.UndeliverableException
import io.reactivex.plugins.RxJavaPlugins

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // flutter_reactive_ble uses RxAndroidBle; BLE errors that arrive after
        // their subscriber is gone would otherwise crash the process
        // (plugin README, "How to handle the BLE undeliverable exception").
        RxJavaPlugins.setErrorHandler { throwable ->
            if (throwable is UndeliverableException && throwable.cause is BleException) {
                return@setErrorHandler
            }
            throw throwable
        }
    }
}
