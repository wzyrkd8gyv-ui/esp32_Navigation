import AVFoundation

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 导航播报：高德把播报文字交给我们，用 iPhone 自带的语音念出来。
/// 播报时把音乐压低（“压低音乐”开关），念完 0.4 秒后恢复；连着蓝牙耳机/头盔时从耳机里出声。
/// iOS v0.16 起支持“圆屏发声”：打开后改用系统语音把文字离线合成成 PCM（手机端不出声），
/// 线性重采样成 16kHz 单声道 Int16 后经 BLE 新增的 AUD 特征值流推给圆屏扬声器播出（与安卓版同一协议）。
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private var automaticVoice: AVSpeechSynthesisVoice?
    private var busy = 0
    private var releaseWork: DispatchWorkItem?
    private(set) var isSpeaking = false

    // ---- iOS v0.16 圆屏发声状态（全部只在 espQueue 上改）----
    private let espSynth = AVSpeechSynthesizer()        // 专用离线合成器：只出 PCM 回调，不出声
    private var espGen = 0                              // 每开一句新播报 +1，旧句的回调作废
    private var espSpeaking = false
    private let espQueue = DispatchQueue(label: "motonav.esp-voice")

    override init() {
        super.init()
        synth.delegate = self
        automaticVoice = Self.preferredChineseVoice()
    }

    /// 只自动选择普通话。用 identifier 稳定排序，避免同级音色随枚举顺序切换。
    private static func preferredChineseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "zh-CN" }
            .sorted { $0.identifier < $1.identifier }
        if #available(iOS 16.0, *) {
            if let premium = voices.first(where: { $0.quality == .premium }) {
                return premium
            }
        }
        return voices.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    private func selectedVoice() -> AVSpeechSynthesisVoice? {
        let id = UserDefaults.standard.string(forKey: "voice_id") ?? ""
        if !id.isEmpty, let selected = AVSpeechSynthesisVoice(identifier: id) {
            return selected
        }
        // 每次自动播报前刷新，下载／删除系统音色后无需重装或修改设置。
        // 不把自动结果写入 voice_id，以便以后继续自动升级音色。
        automaticVoice = Self.preferredChineseVoice()
        return automaticVoice
    }

    private func configureSession(active: Bool) {
        let s = AVAudioSession.sharedInstance()
        do {
            if active {
                let opts: AVAudioSession.CategoryOptions = Settings.shared.duck
                    ? [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
                    : [.mixWithOthers]
                try s.setCategory(.playback, mode: .voicePrompt, options: opts)
                try s.setActive(true)
            } else {
                try s.setActive(false, options: .notifyOthersOnDeactivation)   // 让音乐恢复音量
            }
        } catch {
            print("音频设置失败：\(error)")
        }
    }

    func speak(_ text: String) {
        if Settings.shared.voiceMuted { return }        // iOS v0.6 导航画面上点了静音
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        if Settings.shared.voiceToEsp {
            espSpeak(t)                                 // iOS v0.16 圆屏发声：手机端不念
            return
        }
        localSpeak(t)
    }

    /// 手机端出声（原来那条链路）
    private func localSpeak(_ t: String) {
        releaseWork?.cancel()
        if busy == 0 { configureSession(active: true) }
        busy += 1
        isSpeaking = true
        let u = AVSpeechUtterance(string: t)
        u.voice = selectedVoice()
        u.rate = Float(UserDefaults.standard.object(forKey: "voice_rate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate))
        u.pitchMultiplier = Float(UserDefaults.standard.object(forKey: "voice_pitch") as? Double ?? 1.0)
        synth.speak(u)
    }

    private func finished() {
        busy = max(0, busy - 1)
        if busy == 0 {
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, self.busy == 0 else { return }
                self.isSpeaking = false
                self.configureSession(active: false)
            }
            releaseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
    }

    // MARK: - iOS v0.16 圆屏发声：离线合成 PCM → 重采样 16k 单声道 → BLE 流推给圆屏

    /// 合成并流推一句导航播报（手机端不出声）。用系统自带 write(_:toBufferCallback:) 整段离线合成（iOS 13 起可用，兼容 deployment target iOS 15）。
    private func espSpeak(_ text: String) {
        espQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopEspLocked()                        // 打断上一句（立刻 #AUD,0）
            self.espGen += 1
            let gen = self.espGen
            let u = AVSpeechUtterance(string: text)
            u.voice = self.selectedVoice()
            u.rate = Float(UserDefaults.standard.object(forKey: "voice_rate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate))
            u.pitchMultiplier = Float(UserDefaults.standard.object(forKey: "voice_pitch") as? Double ?? 1.0)
            self.espSpeaking = true
            DispatchQueue.main.async { [weak self] in self?.isSpeaking = true }
            // 整段离线合成（阻塞调用，只出回调不出声）；每段 PCM 都排队进 espQueue，写完自动收尾
            self.espSynth.write(u) { [weak self] buf in
                self?.espQueue.async { self?.appendEspLocked(buf, gen: gen) }
            }
            self.espQueue.async { [weak self] in self?.finishEspLocked(gen) }
        }
    }

    /// 把合成出来的一段 PCM（音色的原生采样率，取第一声道）线性重采样成 16kHz 单声道 Int16 喂给 BleLink
    private func appendEspLocked(_ buf: AVAudioBuffer, gen: Int) {
        guard gen == espGen, espSpeaking, let p = buf as? AVAudioPCMBuffer else { return }
        let n = Int(p.frameLength)
        guard n > 0 else { return }
        let channels = Int(p.format.channelCount)
        let stride = p.format.isInterleaved ? channels : 1
        let raw: UnsafeMutablePointer<Float>
        if let ch = p.floatChannelData?[0] {
            raw = ch
        } else if let d = p.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) {
            raw = d
        } else { return }
        let srcRate = Double(p.format.sampleRate)
        guard srcRate > 0 else { return }
        let ratio = srcRate / 16000.0
        let outN = max(1, Int((Double(n) / ratio).rounded(.up)))
        var pcm = [Int16](repeating: 0, count: outN)
        for i in 0..<outN {
            let f = Double(i) * ratio
            let i0 = min(Int(f), n - 1) * stride
            let i1 = min(Int(f) + stride, (n - 1) * stride)
            let fr = Float(f - floor(f))
            let s = raw[i0] * (1 - fr) + raw[i1] * fr
            let c = s > 1.0 ? 1.0 : (s < -1.0 ? -1.0 : s)
            pcm[i] = Int16(c * 32767.0)
        }
        BleLink.shared.streamAudio(pcm)                 // BleLink 负责 #AUD,1 开头 + 320B/10ms 节奏
    }

    /// 这句播完了：把剩余数据发完并 #AUD,0（多次调用安全）
    private func finishEspLocked(_ gen: Int) {
        guard gen == espGen, espSpeaking else { return }
        espSpeaking = false
        BleLink.shared.finishAudio()
        DispatchQueue.main.async { [weak self] in self?.isSpeaking = false }
    }

    /// 立刻掐断圆屏发声（点静音/切换模式/开新句时调用）
    private func stopEspLocked() {
        espGen += 1                                     // 旧句回调全部作废
        let was = espSpeaking
        espSpeaking = false
        if was { BleLink.shared.stopAudioStream() }     // 立刻 #AUD,0，圆屏马上停
        DispatchQueue.main.async { [weak self] in self?.isSpeaking = false }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished() }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished() }
    }

    /// 马上停止正在念的（点了静音/切换发声模式）
    func stopNow() {
        synth.stopSpeaking(at: .immediate)
        espQueue.async { [weak self] in self?.stopEspLocked() }
    }

    /// 试听（不管静音开关）
    func test() {
        let m = Settings.shared.voiceMuted
        Settings.shared.voiceMuted = false
        speak("前方三百米右转，进入人民南路。注意，前方有测速，限速六十。")
        Settings.shared.voiceMuted = m
    }
}
