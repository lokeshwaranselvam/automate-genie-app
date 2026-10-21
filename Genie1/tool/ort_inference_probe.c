/* Isolated Android inference check; does not install or access the Genie app.
 * Usage: probe /absolute/libonnxruntime.so model.onnx input.f32 output.f32
 * Compile against the matching ONNX Runtime C API header with the Android NDK.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "onnxruntime_c_api.h"

static const OrtApi* api;
static void check(OrtStatus* status) {
  if (status) {
    fprintf(stderr, "%s\n", api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    exit(1);
  }
}

int main(int argc, char** argv) {
  if (argc != 5) return 2;
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  const OrtApiBase* (*get_api)(void) = dlsym(library, "OrtGetApiBase");
  if (!get_api) return 1;
  api = get_api()->GetApi(ORT_API_VERSION);
  if (!api) return 1;
  fprintf(stderr, "ONNX Runtime %s\n", get_api()->GetVersionString());
  OrtEnv* env = NULL;
  OrtSessionOptions* options = NULL;
  OrtSession* session = NULL;
  OrtMemoryInfo* memory = NULL;
  OrtValue* input = NULL;
  OrtValue* output = NULL;
  check(api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "genie-runtime-check", &env));
  check(api->CreateSessionOptions(&options));
  check(api->SetIntraOpNumThreads(options, 2));
  check(api->SetInterOpNumThreads(options, 1));
  check(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL));
  check(api->CreateSession(env, argv[2], options, &session));
  OrtAllocator* allocator = NULL;
  size_t input_count = 0, declared_outputs = 0;
  char* name = NULL;
  check(api->GetAllocatorWithDefaultOptions(&allocator));
  check(api->SessionGetInputCount(session, &input_count));
  check(api->SessionGetOutputCount(session, &declared_outputs));
  if (input_count != 1 || declared_outputs != 1) return 1;
  check(api->SessionGetInputName(session, 0, allocator, &name));
  if (strcmp(name, "data")) return 1;
  allocator->Free(allocator, name);
  check(api->SessionGetOutputName(session, 0, allocator, &name));
  if (strcmp(name, "fc1")) return 1;
  allocator->Free(allocator, name);
  const size_t count = 3 * 112 * 112;
  float* tensor = calloc(count, sizeof(float));
  if (!tensor) return 1;
  FILE* file = fopen(argv[3], "rb");
  if (!file || fread(tensor, sizeof(float), count, file) != count) return 1;
  fclose(file);
  int64_t shape[] = {1, 3, 112, 112};
  check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
  check(api->CreateTensorWithDataAsOrtValue(memory, tensor,
      count * sizeof(float), shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input));
  const char* inputs[] = {"data"};
  const char* outputs[] = {"fc1"};
  check(api->Run(session, NULL, inputs, (const OrtValue* const*)&input,
      1, outputs, 1, &output));
  OrtTensorTypeAndShapeInfo* info = NULL;
  size_t output_count = 0;
  check(api->GetTensorTypeAndShape(output, &info));
  check(api->GetTensorShapeElementCount(info, &output_count));
  if (output_count != 128) return 1;
  float* features = NULL;
  check(api->GetTensorMutableData(output, (void**)&features));
  file = fopen(argv[4], "wb");
  if (!file || fwrite(features, sizeof(float), output_count, file) != output_count) return 1;
  fclose(file);
  api->ReleaseTensorTypeAndShapeInfo(info);
  api->ReleaseValue(output);
  api->ReleaseValue(input);
  api->ReleaseMemoryInfo(memory);
  api->ReleaseSession(session);
  api->ReleaseSessionOptions(options);
  api->ReleaseEnv(env);
  free(tensor);
  dlclose(library);
  return 0;
}
