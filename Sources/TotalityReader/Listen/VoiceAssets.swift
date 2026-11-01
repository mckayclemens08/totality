import CryptoKit
import Foundation

/// FluidAudio 0.18.0 downloads part of the voice from a branch that can change, with no hash check, and
/// loads it into this app. So that part is fetched here first, from one commit, against hashes compiled
/// in, and FluidAudio finds it on disk and leaves it alone. Check all of this when the FluidAudio pin moves.
enum VoiceAssets {
    typealias Fetch = @Sendable (URL) async throws -> Data
    static let fromNetwork: Fetch = { try await URLSession.shared.data(from: $0).0 }

    static let voice = "am_michael"
    private static let voiceHash = "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"
    private static let commit = "2568276a60ff6e7f312afce3dc9e3f07521cb48d"
    /// Where FluidAudio keeps its files, under the commit it pins them to.
    private static let base = "kokoro-82m-coreml/ANE-v3/6c0750dd02ef9d981fb82f147d784a3f171755ee/en"

    static let files: [(path: String, sha256: String)] = [
        ("G2PDecoder.mlmodelc/analytics/coremldata.bin", "dbf1767747fdc188222d467a45b04608b396c76c71db3abb18a5fb3680ef9827"),
        ("G2PDecoder.mlmodelc/coremldata.bin", "607e960f19b4d9a30317a5a11869fcce84b300a909fcab2cc756c0d98e2dacd9"),
        ("G2PDecoder.mlmodelc/metadata.json", "e54e98484fd60d26f22fd3c4e7fe87b0d92a5d2de1f958cc3c4bb36d4ae06a44"),
        ("G2PDecoder.mlmodelc/model.mil", "fe647c598e0d9454d360b8ee49a59ae57ca147fc5330863ba84ccb90dce482ad"),
        ("G2PDecoder.mlmodelc/weights/weight.bin", "cbaeb4e743359f607ab161af0c6d8a817462fdaec622ee788ef8ef952c5f8214"),
        ("G2PEncoder.mlmodelc/analytics/coremldata.bin", "cf7fbd7e7a65529b2d2bf3941e458a0ab6dff7a298bf48e205a1727c81c26a99"),
        ("G2PEncoder.mlmodelc/coremldata.bin", "0f14d46ca9fd06c68b4717294575b2b99449e67d40b7a2c56f926bf05cd90b11"),
        ("G2PEncoder.mlmodelc/metadata.json", "c8e0cfd7f494ac1b3662ff8f1914b2b45f79ffb2791724cdc0576981996732e1"),
        ("G2PEncoder.mlmodelc/model.mil", "8c617e569f37286b056dad800d862dc145be9a95fa9ed43857bb646ba199d7da"),
        ("G2PEncoder.mlmodelc/weights/weight.bin", "6926bcd2827d21fec82839487b987e06f85fd8a6a5bb896bc4f6062461d014ec"),
        ("g2p_vocab.json", "295ed64b86c2820cd665b0602ae50c6947c0e82ac643082873e0be87dca282ce"),
        ("us_lexicon_cache.json", "6b36ba313202227d6914ad32cd684a0304bd2757e9ec4158ea7bc36ec40e224e"),
    ]

    static func install(
        in directory: URL,
        files: [(path: String, sha256: String)] = files,
        fetch: Fetch = fromNetwork
    ) async throws {
        for file in files {
            let local = directory.appendingPathComponent("kokoro/\(file.path)")
            if let saved = try? Data(contentsOf: local), hash(saved) == file.sha256 { continue }
            let address = "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/\(commit)/\(file.path)"
            guard let url = URL(string: address) else { throw VoiceLoadError.badFile }
            let data = try await fetch(url)
            guard hash(data) == file.sha256 else { throw VoiceLoadError.badFile }
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: local, options: .atomic)
        }
        // FluidAudio checks its base models against this listing, and reads it from the network if it's missing.
        let listing = directory.appendingPathComponent("\(base)/base-index-v3.json")
        try FileManager.default.createDirectory(at: listing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(baseListing.utf8).write(to: listing, options: .atomic)
    }

    /// FluidAudio doesn't hash voice packs, so Michael's is checked once it has arrived.
    static func checkVoice(in directory: URL) throws {
        let file = voiceFile(in: directory)
        guard let saved = try? Data(contentsOf: file), hash(saved) == voiceHash else {
            try? FileManager.default.removeItem(at: file)
            throw VoiceLoadError.badFile
        }
    }

    static func voiceFile(in directory: URL) -> URL {
        directory.appendingPathComponent("\(base)/voices/\(voice).bin")
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let baseListing = #"[{"oid":"e34b4d1b7a82d0d2e25110b7cbd05f6d8fc67ac1","lfs":{"oid":"1efeed89cf916ee5fd38a7b4aef8d79a6444eef6b5521514c5ab34e7164f36a2"},"size":92156,"path":"ANE\/KokoroAlbert.mlpackage\/Data\/com.apple.CoreML\/model.mlmodel","type":"file"},{"size":5718848,"type":"file","oid":"3ea054a139169a5f302b6326f08b9393b20a2818","path":"ANE\/KokoroAlbert.mlpackage\/Data\/com.apple.CoreML\/weights\/weight.bin","lfs":{"oid":"36089a39359b800d3e2c60e5e8ac9217d8f2d1010a8b9273192290e621f1fabc"}},{"size":617,"type":"file","oid":"e25699d8505057bd948dc7cdc94c165d3132917f","path":"ANE\/KokoroAlbert.mlpackage\/Manifest.json"},{"type":"file","oid":"e780e55688c0640578a90a1d7d149f7726070bed","path":"ANE\/KokoroAlignment.mlpackage\/Data\/com.apple.CoreML\/model.mlmodel","size":6971,"lfs":{"oid":"2d87764d55eb2bdf4ea9ced45b63ff51b4a0e139d5440b2d52c03076f06d8512"}},{"path":"ANE\/KokoroAlignment.mlpackage\/Data\/com.apple.CoreML\/weights\/weight.bin","size":4128,"oid":"6104dbdaf764de798e11c12c90ac8fa596b41bd5","type":"file","lfs":{"oid":"2e7d69128b59d615fc3d3cf85637a687235fc086b1eb136359adb11a61615f6b"}},{"path":"ANE\/KokoroAlignment.mlpackage\/Manifest.json","size":617,"oid":"2f2208d744d6efc9ddea31784f94f429189aff5b","type":"file"},{"lfs":{"oid":"894168c950938e0b776f010b4278b1aae65aa1ce3dd8bdfa4c4170ca80362d0d"},"oid":"5cc566d7ff5899f37afeb4cdbe00ff3e2656049c","path":"ANE\/KokoroNoise_v2.mlpackage\/Data\/com.apple.CoreML\/model.mlmodel","type":"file","size":76250},{"path":"ANE\/KokoroNoise_v2.mlpackage\/Data\/com.apple.CoreML\/weights\/weight.bin","lfs":{"oid":"1102fc2d31dfcfe3de3978a4c78b65202ff8b0a4d55a9304213bd4e8bda66bc2"},"size":4580160,"type":"file","oid":"d81342c6856d163be9c9f601092883f763f8170a"},{"path":"ANE\/KokoroNoise_v2.mlpackage\/Manifest.json","type":"file","size":617,"oid":"2d85221aacada2e984c45d5243bf95c2ff83e032"},{"size":49183,"path":"ANE\/KokoroPostAlbert.mlpackage\/Data\/com.apple.CoreML\/model.mlmodel","lfs":{"oid":"5b1ec258a17ca6419da5c90c66e147a7c3699ea3ed620c4b0db715f6b3f5aa26"},"type":"file","oid":"138c538a596c5627044223454e60931a95637224"},{"type":"file","lfs":{"oid":"e4f300a23cc2e05d38680d9fc94681cc722d445076d1d248f83255122ba091c8"},"size":13806464,"path":"ANE\/KokoroPostAlbert.mlpackage\/Data\/com.apple.CoreML\/weights\/weight.bin","oid":"b69a4f75779298b1bbd5c56a3ef3d68c980f2eb3"},{"oid":"c7eb11b86c1ed2c05ea6e4962a5402a6a0697996","path":"ANE\/KokoroPostAlbert.mlpackage\/Manifest.json","size":617,"type":"file"},{"path":"ANE\/KokoroProsody_v2.mlmodelc\/analytics\/coremldata.bin","size":243,"lfs":{"oid":"804d7d2e9a8fed345cedb57da61bd27fdd95db22a070cfa7d42ccd4f8e80a443"},"oid":"55c5a25a5080666919c9363717cecbd628e96f9e","type":"file"},{"oid":"48dd20e5e80818a8a1c92b5ece72d73c111ea42a","type":"file","size":421,"path":"ANE\/KokoroProsody_v2.mlmodelc\/coremldata.bin","lfs":{"oid":"db8776a4896f690fd254cdb68a4551c168411c9b3fb98219630215bc3c357986"}},{"path":"ANE\/KokoroProsody_v2.mlmodelc\/model.mil","oid":"989a67f877974a78dae29fb5b9a331783df55be8","size":73353,"type":"file"},{"lfs":{"oid":"70eea4cd2523992fa1fea840e31ab6f4fdd69c1598e220985a2ae6ea5da1e944"},"size":8513664,"type":"file","path":"ANE\/KokoroProsody_v2.mlmodelc\/weights\/weight.bin","oid":"626371a81839764315507f8319b53fe19c262a67"},{"path":"ANE\/KokoroTail_v2.mlmodelc\/analytics\/coremldata.bin","type":"file","oid":"e0d13de333d78cb4e5d4c25df52dab4d447457c1","size":243,"lfs":{"oid":"a06e4b91c2b8a8be3ff701558a5f1f6484921f948202663fe6df78f248d42222"}},{"oid":"104166a1da8fae22b2d0fbaab0aef355915f3151","size":392,"path":"ANE\/KokoroTail_v2.mlmodelc\/coremldata.bin","lfs":{"oid":"527271f6df56cc308a5f89374c92108aef7b837ab15f0ba4900d555588dbd905"},"type":"file"},{"size":1872,"path":"ANE\/KokoroTail_v2.mlmodelc\/metadata.json","oid":"7b64b026357b111557d44d7b80f14f27b01c39f2","type":"file"},{"size":7014,"type":"file","path":"ANE\/KokoroTail_v2.mlmodelc\/model.mil","oid":"24c17efb2e66b789ab3329a6b00bdaa29fc1695e"},{"type":"file","path":"ANE\/KokoroTail_v2.mlmodelc\/weights\/weight.bin","oid":"21f8ff72d34f81c715fa7c952cd483a60fccd1b0","lfs":{"oid":"8ede31ec20df7d86a124287ac12d13507651e2a693e9d4f35f0e7f92cba422c7"},"size":81088},{"type":"file","lfs":{"oid":"18481f9531abd0d01cf6fe6b8837b98263e8a63d87db56324d49ed57cc5c75fa"},"size":255741,"path":"ANE\/KokoroVocoder.mlpackage\/Data\/com.apple.CoreML\/model.mlmodel","oid":"138bfd648044bbc2573fea879fef6de8fd4cf1a1"},{"oid":"fb88aab245ab34ccf07fc8f69bba1f78c2f20e86","path":"ANE\/KokoroVocoder.mlpackage\/Data\/com.apple.CoreML\/weights\/weight.bin","type":"file","lfs":{"oid":"6d1f96eb50218ab687b12d6d862d2ae854c12b7165c3cd9b6b5cef261ef02ff1"},"size":48889920},{"path":"ANE\/KokoroVocoder.mlpackage\/Manifest.json","oid":"6286acebfa580f4abed593c3337d42c917b3e9da","size":617,"type":"file"}]"#
}
