"""Prepare the official SFace INT8 block model for single-input ONNX Runtime.

Developer tool: requires onnx; never runs in the mobile app or Frappe Safe Exec.
Usage: python tool/prepare_sface_int8bq.py downloaded.onnx output.onnx
"""
import hashlib
from pathlib import Path
import sys

import onnx

SOURCE_SHA256 = "fb143eea07838aa532d1c95df5f69899974ea0140e1fba05e94204be13ed74ee"


def prepare(source, output):
    source = Path(source)
    output = Path(output)
    if source.resolve() == output.resolve():
        raise ValueError("Use a separate output file.")
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise ValueError("The source is not the verified official INT8 block model.")
    model = onnx.load(str(source))
    weights = [value.SerializeToString() for value in model.graph.initializer]
    operators = [value.SerializeToString() for value in model.graph.node]
    produced = {name for node in model.graph.node for name in node.output}
    consumed = {name for node in model.graph.node for name in node.input}
    initializers = {value.name for value in model.graph.initializer}
    for value in list(model.graph.input):
        if value.name == "data":
            continue
        if (value.name in consumed and value.name not in produced
                and value.name not in initializers):
            raise ValueError("Unexpected required input: " + value.name)
        model.graph.input.remove(value)
    if [value.name for value in model.graph.input] != ["data"]:
        raise ValueError("Expected one image tensor input named data.")
    assert weights == [value.SerializeToString() for value in model.graph.initializer]
    assert operators == [value.SerializeToString() for value in model.graph.node]
    onnx.checker.check_model(model)
    output.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, str(output))
    print("Prepared", output, "with unchanged weights and operators.")
    print("SHA-256:", hashlib.sha256(output.read_bytes()).hexdigest())


if __name__ == "__main__":
    prepare(*sys.argv[1:])
