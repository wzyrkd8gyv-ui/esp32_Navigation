import AVFoundation

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 导航播报：高德把播报文字交给我们，用 iPhone 自带的语音念出来。
/// 播报时把音乐压低（“压低音乐”开关），念完 0.4 秒后恢复；连着蓝牙耳机/头盔时从耳机里出声。
/// iOS v0.16 起支持“圆屏发声”：打开后改用系统语音把文字合成成 16kHz 单声道 PCM，
/// 经 BLE 新增的 AUD 特征值流推给圆屏扬声器播出，手机端不出声（与安卓版同一协议）。
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private var automaticVoice: AVSpeechSynthesisVoice?
    private var busy = 0
    private var releaseWork: DispatchWorkItem?
    private(set) var isSpeaking = false

    // ---- iOS v0.16 圆屏发声状态（全部只在 espQueue 上改）----
    private var espGen = 0                            // 每开一句新播报 +1，旧句的回调作废
    private var espSpeaking = false
    private var espIds = Set<ObjectIdentifier>()      // 当前这句的请求对象
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

    // MARK: - iOS v0.16 圆屏发声：合成 16kHz 单声道 PCM → BLE 流推给圆屏

    /// 合成并流推一句导航播报（手机端不出声）。系统 < iOS 17 时退回手机出声。
    private func espSpeak(_ text: String) {
        guard #available(iOS 17.0, *) else {
            localSpeak(text)
            return
        }
        espQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopEspLocked()                        // 打断上一句（立刻 #AUD,0）
            self.espGen += 1
            let gen = self.espGen
            let u = AVSpeechUtterance(string: text)
            u.voice = self.selectedVoice()
            u.rate = Float(UserDefaults.standard.object(forKey: "voice_rate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate))
            u.pitchMultiplier = Float(UserDefaults.standard.object(forKey: "voice_pitch") as? Double ?? 1.0)
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000, channels: 1,
                                          interleaved: false) else { return }
            let req = AVSpeechSynthesisBufferRequest(utterance: u, outputFormat: fmt)
            self.espIds.insert(ObjectIdentifier(req))
            req.didReceiveOutputBuffer = { [weak self] buf in
                self?.espQueue.async { self?.appendEspLocked(buf, gen: gen) }
            }
            req.didFinish = { [weak self] in
                self?.espQueue.async { self?.finishEspLocked(gen) }
            }
            self.espSpeaking = true
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = true
                self?.synth.write(req)                  // 离线合成：只出 PCM 回调，不出声
            }
        }
    }

    /// 把合成出来的一段 Float32 PCM（已是 16kHz 单声道）转 Int16 喂给 BleLink
    private func appendEspLocked(_ buf: AVAudioPCMBuffer, gen: Int) {
        guard gen == espGen, espSpeaking, let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let v = Double(ch[i])
            let c = v > 1.0 ? 1.0 : (v < -1.0 ? -1.0 : v)
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
        espIds.removeAll()
        let was = espSpeaking
        espSpeaking = false
        if was { BleLink.shared.stopAudioStream() }     // 立刻 #AUD,0，圆屏马上停
        DispatchQueue.main.async { [weak self] in self?.isSpeaking = false }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded(u) }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded(u) }
    }

    /// 圆屏发声的合成走 write()，也会走到这两个回调：是 ESP 句就在 espQueue 上收尾，否则走手机端收尾
    private func utteranceEnded(_ u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        espQueue.async { [weak self] in
            guard let self = self else { return }
            if self.espIds.remove(id) != nil {
                self.finishEspLocked(self.espGen)       // 被取消时 gen 已作废，自然 no-op
                return
            }
            DispatchQueue.main.async { self.finished() }
        }
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
