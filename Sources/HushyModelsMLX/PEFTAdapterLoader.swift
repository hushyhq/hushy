import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// SPIKE (docs/product/FINETUNE.md §3.27, §3.32): loads a Hugging Face PEFT LoRA adapter — what
/// `scripts/finetune/cuda/train_cuda.py` writes to `runs/<run>/adapter/` — onto an already loaded
/// 4-bit model, *unfused*: every targeted `QuantizedLinear` becomes a `QLoRALinear`
/// (`y = qmatmul(x) + scale·(x·A)·B`). Used only to measure what separate runtime adapters would
/// cost; the shipping path stays one merged model.
///
/// mlx-swift-lm's own `LoRAContainer.fromPEFT` can't read our adapters: `train_cuda.py` saves
/// `target_modules` as one regex string (PEFT allows either), and the tensors are named after the
/// multimodal Hugging Face class (`base_model.model.model.language_model.layers.N…`), while the
/// text-only MLX conversion loads as `Qwen35Model` (`language_model.model.layers.N…`).
enum PEFTAdapterLoader {
    struct Summary: Sendable {
        var tensors: Int
        var parameters: Int
        var bytes: Int
        var rank: Int
        var scale: Float
    }

    /// Loads `directory`'s adapter into `model`. A/B are cast to `dtype` (bf16: what training used;
    /// PEFT saves fp32).
    static func load(_ directory: URL, into model: any LanguageModel, dtype: DType = .bfloat16) throws -> Summary {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(component: "adapter_config.json"))) as? [String: Any] ?? [:]
        guard let rank = config["r"] as? Int, let alpha = (config["lora_alpha"] as? NSNumber)?.floatValue else {
            throw ModelAdapterError.unsupportedAdapterType("adapter_config.json without r / lora_alpha")
        }
        let raw = try MLX.loadArrays(url: directory.appending(component: "adapter_model.safetensors"))
        var renamed: [String: MLXArray] = [:]
        var keys = Set<String>()
        var parameters = 0
        for (key, tensor) in raw {
            let isA = key.hasSuffix(".lora_A.weight"), isB = key.hasSuffix(".lora_B.weight")
            guard isA || isB else { continue }
            var path = String(key.dropLast(".lora_A.weight".count))
            for prefix in ["base_model.model.", "model."] where path.hasPrefix(prefix) {
                path = String(path.dropFirst(prefix.count))
            }
            // language_model.layers.N.x → language_model.model.layers.N.x (text-only MLX layout)
            if path.hasPrefix("language_model.layers.") {
                path = "language_model.model." + path.dropFirst("language_model.".count)
            }
            if let range = path.range(of: #"layers\.\d+\."#, options: .regularExpression) {
                keys.insert(String(path[range.upperBound...]))
            }
            // PEFT: A [r, in], B [out, r]; MLX: lora_a [in, r], lora_b [r, out].
            renamed[path + (isA ? ".lora_a" : ".lora_b")] = tensor.transposed().asType(dtype)
            parameters += tensor.size
        }
        let configuration = LoRAConfiguration(
            numLayers: 1_024, fineTuneType: .lora,
            loraParameters: .init(rank: rank, scale: alpha / Float(rank), dropout: 0, keys: keys.sorted()))
        let container = LoRAContainer(configuration: configuration, parameters: ModuleParameters.unflattened(renamed))
        try model.load(adapter: container)
        return Summary(tensors: renamed.count, parameters: parameters, bytes: parameters * dtype.size, rank: rank, scale: alpha / Float(rank))
    }
}
