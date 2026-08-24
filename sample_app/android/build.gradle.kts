allprojects {
    repositories {
        google()
        mavenCentral()
        // Local flat-file Maven repo (`./gradlew publish` from ota_runtime_android/, repo root) —
        // convenient inside this monorepo only.
        maven { url = uri(rootProject.projectDir.resolve("../../maven-repo")) }
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
    if (project.name != "app") {
        project.evaluationDependsOn(":app")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
