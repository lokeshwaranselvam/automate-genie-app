/* Android app_process smoke test for the unchanged published Java/JNI bridge.
 * Compile with the published ORT 1.28.0 classes.jar, then dex both with d8.
 * Usage: OrtJavaProbe model.onnx input.f32 output.f32
 * Runs as adb shell and never opens the employee app or its private storage.
 */
import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.HashMap;
import java.util.Map;

public final class OrtJavaProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 3) throw new IllegalArgumentException("model input output required");
        byte[] bytes = new byte[3 * 112 * 112 * 4];
        try (FileInputStream input = new FileInputStream(args[1])) {
            int offset = 0;
            while (offset < bytes.length) {
                int read = input.read(bytes, offset, bytes.length - offset);
                if (read < 0) throw new IllegalArgumentException("Truncated input tensor");
                offset += read;
            }
        }
        FloatBuffer values = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();
        System.out.println("Probe: input ready");
        OrtEnvironment env = OrtEnvironment.getEnvironment();
        System.out.println("Probe: environment ready");
        try (OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
            options.setIntraOpNumThreads(2);
            options.setInterOpNumThreads(1);
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
            System.out.println("Probe: session options ready");
            try (OrtSession session = env.createSession(args[0], options);
                 OnnxTensor tensor = OnnxTensor.createTensor(env, values, new long[]{1, 3, 112, 112})) {
                System.out.println("Probe: session and input tensor ready");
                if (!session.getInputNames().contains("data") || !session.getOutputNames().contains("fc1")) {
                    throw new IllegalStateException("Unexpected model input/output metadata");
                }
                // Exercise metadata APIs used by flutter_onnxruntime as well.
                session.getInputInfo();
                session.getOutputInfo();
                System.out.println("Probe: metadata ready");
                Map<String, OnnxTensor> inputs = new HashMap<>();
                inputs.put("data", tensor);
                try (OrtSession.Result result = session.run(inputs)) {
                    System.out.println("Probe: inference returned");
                    float[][] output = (float[][]) result.get(0).getValue();
                    if (output.length != 1 || output[0].length != 128) {
                        throw new IllegalStateException("Expected 128 face features");
                    }
                    // Flutter reads floatBuffer for asFlattenedList(). Exercise
                    // that JNI path as well as the structured getValue() path.
                    float[] flattened = new float[128];
                    ((OnnxTensor) result.get(0)).getFloatBuffer().get(flattened);
                    ByteBuffer packed = ByteBuffer.allocate(128 * 4).order(ByteOrder.LITTLE_ENDIAN);
                    for (int index = 0; index < flattened.length; index++) {
                        float value = flattened[index];
                        if (Float.floatToIntBits(value) != Float.floatToIntBits(output[0][index])) {
                            throw new IllegalStateException("JNI output access paths disagree");
                        }
                        if (Float.isNaN(value) || Float.isInfinite(value)) {
                            throw new IllegalStateException("Non-finite model output");
                        }
                        packed.putFloat(value);
                    }
                    try (FileOutputStream file = new FileOutputStream(args[2])) {
                        file.write(packed.array());
                    }
                }
            }
        }
        System.out.println("Java/JNI metadata and inference passed");
    }
}
