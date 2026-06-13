allprojects {
    repositories {
        google()
        mavenCentral()
    }
    // Suppress "source/target value 8 is obsolete" warnings from third-party plugins
    // (razorpay_flutter, image_picker_android) that still declare Java 8 compatibility.
    afterEvaluate {
        tasks.withType<JavaCompile> {
            options.compilerArgs.add("-Xlint:-options")
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
