#!/bin/bash
# 个人定制补丁（release-ios.yml 构建前执行）：
#   1) Bundle ID: com.example.motonav -> org.esp32nav.motonav（高德 Key 绑定此 ID，含 .share 扩展）
#   2) BleLink.swift 加「连上自动校时」：验证通过 / 连上就绪 / 每 2 秒心跳 发送 #TIME,<epoch秒>,<时区偏移秒>
set -euo pipefail

python3 - <<'PYEOF'
import sys

pbx = "ios/MotoNav.xcodeproj/project.pbxproj"
s = open(pbx, encoding="utf-8").read()
n = s.count("com.example.motonav")
assert n == 4, f"bundle id occurrences={n}"
s = s.replace("com.example.motonav", "org.esp32nav.motonav")
open(pbx, "w", encoding="utf-8").write(s)
print(f"[patch] bundle id -> org.esp32nav.motonav ({n} places)")

f = "ios/MotoNav/BleLink.swift"
s = open(f, encoding="utf-8").read()

a_vars = "    private var pumpScheduled = false\n"
r_vars = a_vars + """    private var clockSyncElapsed: Double = 0        // 上次校时（系统 uptime 秒）
    private var clockSyncWall: Int64 = 0            // 上次校时（墙钟毫秒）
    private var clockSyncOffset = 0                 // 上次校时（时区偏移秒）
"""
assert s.count(a_vars) == 1, "vars anchor"
s = s.replace(a_vars, r_vars, 1)

a_hb = "            self?.requestBuildingCapability()\n"
r_hb = a_hb + "            self?.syncClock(force: false)\n"
assert s.count(a_hb) == 1, "heartbeat anchor"
s = s.replace(a_hb, r_hb, 1)

a_ready = """        MapFeeder.shared.resendAll()                    // 圆屏可能重启过：地图块和路线重发
    }
}
"""
r_ready = """        MapFeeder.shared.resendAll()                    // 圆屏可能重启过：地图块和路线重发
        syncClock(force: true)                          // 连上后立刻对一次钟（固件收到 U,1 后执行）
    }

    /// 连上并通过验证后把手机时间同步给圆屏：#TIME,<epoch秒>,<时区偏移秒>（与安卓版同一协议）
    /// 60 秒内 / 时区没变 / 墙钟没漂移超过 2 秒时跳过，避免每次都发。
    private func syncClock(force: Bool) {
        guard isReady, verified else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime
        let wall = Int64(Date().timeIntervalSince1970 * 1000)
        let offset = TimeZone.current.secondsFromGMT()
        if !force, elapsed - clockSyncElapsed < 60, offset == clockSyncOffset,
           abs((wall - clockSyncWall) - Int64((elapsed - clockSyncElapsed) * 1000)) < 2000 { return }
        let seconds = wall / 1000
        guard wall >= 1577836800000, seconds < 4102444800, offset >= -50400, offset <= 50400 else { return }
        enqueue("CLOCK", Data(("#TIME," + String(seconds) + "," + String(offset)).utf8))
        clockSyncElapsed = elapsed; clockSyncWall = wall; clockSyncOffset = offset
        pump()
    }
}
"""
assert s.count(a_ready) == 1, "ready anchor"
s = s.replace(a_ready, r_ready, 1)

a_auth = "MapFeeder.shared.resendAll(); return\n"
r_auth = """MapFeeder.shared.resendAll()
            syncClock(force: true)                     // 验证通过：立即把手机时间同步给圆屏
            return
"""
assert s.count(a_auth) == 1, "auth anchor"
s = s.replace(a_auth, r_auth, 1)

open(f, "w", encoding="utf-8").write(s)
print("[patch] BleLink.swift clock sync added")
PYEOF
