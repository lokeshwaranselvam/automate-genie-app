param(
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [Parameter(Mandatory=$true)][string]$AndroidSdk,
    [Parameter(Mandatory=$true)][string]$AndroidNdk,
    [Parameter(Mandatory=$true)][string]$CMakePath,
    [Parameter(Mandatory=$true)][string]$NinjaDirectory,
    [Parameter(Mandatory=$true)][string]$BuildRoot,
    [string]$DependencyMirror,
    [ValidateSet('arm64-v8a','armeabi-v7a','x86_64')]
    [string[]]$Abis = @('arm64-v8a','armeabi-v7a','x86_64'),
    [ValidateRange(1,16)][int]$Jobs = 2
)

$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
if ((Get-Content -LiteralPath (Join-Path $sourcePath 'VERSION_NUMBER') -Raw).Trim() -ne '1.28.0') {
    throw 'This configuration is validated only for ONNX Runtime 1.28.0.'
}
$opsConfig = Join-Path $PSScriptRoot 'sface-required-operators.config'
$modelPath = Join-Path $PSScriptRoot '../../assets/face_recognition/sface_2021dec.onnx'
if ((Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
    '487a139eb85ccd5ff30aef7d0add7f12d2bb7abb90c5f08a7f481b452a660e00') {
    throw 'The face model changed. Regenerate and validate the operator configuration first.'
}
$env:PATH = $NinjaDirectory + ';' + (Split-Path $CMakePath) + ';' + $env:PATH
$cmakeDefinitions = @('onnxruntime_BUILD_UNIT_TESTS=OFF', 'onnxruntime_BUILD_BENCHMARKS=OFF')
if ($DependencyMirror) {
    $cmakeDefinitions += 'onnxruntime_CMAKE_DEPS_MIRROR_DIR=' + $DependencyMirror.Replace('\','/')
}
Push-Location -LiteralPath $sourcePath
try {
    foreach ($abi in $Abis) {
        $abiBuild = Join-Path $BuildRoot $abi
        $arguments = @(
            'tools/ci_build/build.py', '--build_dir', $abiBuild, '--config', 'Release',
            '--android', '--android_sdk_path', $AndroidSdk, '--android_ndk_path', $AndroidNdk,
            '--android_abi', $abi, '--android_api', '24', '--cmake_generator', 'Ninja',
            '--cmake_path', $CMakePath, '--include_ops_by_config', $opsConfig,
            '--build_shared_lib', '--use_nnapi', '--disable_ml_ops', '--skip_tests', '--skip_submodule_sync',
            '--parallel', "$Jobs", '--cmake_extra_defines'
        ) + $cmakeDefinitions
        # Python's build logger writes normal progress to stderr. Windows
        # PowerShell must judge the exit code, rather than stop on that stream.
        $savedErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & python @arguments
            $buildExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorAction
        }
        if ($buildExitCode -ne 0) { throw "ONNX Runtime build failed for $abi." }
        if (-not (Test-Path -LiteralPath (Join-Path $abiBuild 'Release/libonnxruntime.so'))) {
            throw "Native runtime was not produced for $abi."
        }
    }
} finally {
    Pop-Location
}
