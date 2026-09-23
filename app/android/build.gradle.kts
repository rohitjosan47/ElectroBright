allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// reactive_ble_mobile 5.6.0 declares `compileSdkVersion 37`, beyond the
// maximum AGP 9.1 supports (36); SDK 37 also installs as "android-37.0",
// which AGP 9.1 cannot resolve from the plain `37`. The plugin uses no API 37
// symbols, so compile it against the app's SDK 36 (this also keeps its AAR
// metadata minCompileSdk at 36). Registered before the plugin's own script
// runs, so it executes ahead of AGP's afterEvaluate finalisation. Remove once
// the Flutter template moves to an AGP that supports SDK 37.
subprojects {
    if (name == "reactive_ble_mobile") {
        afterEvaluate {
            val android = extensions.getByName("android")
            android.javaClass.getMethod("compileSdkVersion", String::class.java)
                .invoke(android, "android-36")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
