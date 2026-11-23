// Perfis prontos da galeria. Rótulos, nomes e descrições em inglês.
// Perfis em 3×5 (cabem em qualquer celular deitado). Nomes de ícone do app (button_icons.dart).
(function () {
  const G = "#37474F", RED = "#B71C1C", GREEN = "#1B5E20", BLUE = "#0D47A1", PURPLE = "#4A148C";
  const act = (type, parameters) => ({ type, parameters });
  const L = en => ({ en });
  const btn = (row, column, label, iconName, action, extra = {}) =>
    ({ id: `${row}-${column}`, row, column, label, iconName, backgroundColor: G, action, ...extra });
  const micMute = act("mixer", { operation: "toggleMute", deviceId: "default", deviceKind: "input" });

  const PREV = L("Prev"), PLAY = L("Play"), NEXT = L("Next");
  const MIC = L("Mic"), DEAF = L("Deafen"), LOCK = L("Lock");
  const CLOCK = L("Clock"), CLIP = L("Clip");

  const PROFILES = [
    {
      key: "streamer",
      name: L("Streamer"),
      desc: L("OBS live and recording, Discord mic, break timer, a counter, music and volume."),
      buttons: [
        btn(0, 0, L("Live"), "smart_display", act("obs", { operation: "toggleStream" }), { backgroundColor: RED }),
        btn(0, 1, L("REC"), "videocam", act("obs", { operation: "toggleRecord" }), { backgroundColor: RED }),
        btn(0, 2, CLIP, "save", act("obs", { operation: "saveReplay" })),
        btn(0, 3, L("Marker"), "flag", act("obs", { operation: "createChapter" })),
        btn(0, 4, L("Cam"), "camera", act("obs", { operation: "toggleVirtualCam" })),
        btn(1, 0, MIC, "mic", act("discord", { operation: "toggleMute" }), { backgroundColor: PURPLE, activeLabel: L("Muted"), activeIconName: "mic_off" }),
        btn(1, 1, DEAF, "headphones", act("discord", { operation: "toggleDeafen" }), { backgroundColor: PURPLE }),
        btn(1, 2, L("Break"), "timer", act("timer", { mode: "countdown", durationMin: "5", operation: "toggle" })),
        btn(1, 3, L("Deaths"), "sports_esports", act("timer", { mode: "counter", operation: "increment", step: "1" })),
        btn(1, 4, L("CPU"), null, null, { dynamicType: "cpu_monitor" }),
        btn(2, 0, PREV, "arrow_back", act("media", { command: "previous" })),
        btn(2, 1, PLAY, "play", act("media", { command: "playpause" }), { backgroundColor: GREEN }),
        btn(2, 2, L("Music"), null, null, { dynamicType: "now_playing", columnSpan: 2 }),
        btn(2, 4, L("Volume"), null, null, { dynamicType: "volume_slider", dynamicParameters: { target: "output" } }),
      ],
    },
    {
      key: "meetings",
      name: L("Meetings"),
      desc: L("Mute and camera for Teams, Zoom and Meet, your PC mic, notifications and lock."),
      buttons: [
        btn(0, 0, MIC, "mic", micMute, { backgroundColor: RED, toggle: false }),
        btn(0, 1, L("Teams mic"), "mic_off", act("hotkey", { keys: "^+m" })),
        btn(0, 2, L("Teams cam"), "videocam_off", act("hotkey", { keys: "^+o" })),
        btn(0, 3, L("Hand"), "flag", act("hotkey", { keys: "^+k" })),
        btn(0, 4, L("Leave"), "call_end", act("hotkey", { keys: "^+h" }), { backgroundColor: RED }),
        btn(1, 0, L("Zoom mic"), "mic_off", act("hotkey", { keys: "%a" }), { backgroundColor: BLUE }),
        btn(1, 1, L("Zoom cam"), "videocam_off", act("hotkey", { keys: "%v" }), { backgroundColor: BLUE }),
        btn(1, 2, L("Meet mic"), "mic_off", act("hotkey", { keys: "^d" }), { backgroundColor: GREEN }),
        btn(1, 3, L("Meet cam"), "videocam_off", act("hotkey", { keys: "^e" }), { backgroundColor: GREEN }),
        btn(1, 4, CLOCK, null, null, { dynamicType: "clock" }),
        btn(2, 0, L("Vol −"), "volume_off", act("mixer", { operation: "volumeDown", deviceId: "default" })),
        btn(2, 1, L("Vol +"), "volume_up", act("mixer", { operation: "volumeUp", deviceId: "default" })),
        btn(2, 2, L("Alerts"), null, null, { dynamicType: "notifications" }),
        btn(2, 3, LOCK, "lock", act("windows", { operation: "lock" })),
        btn(2, 4, L("Focus"), "notifications_off", act("hotkey", { keys: "#n" })),
      ],
    },
    {
      key: "music",
      name: L("Music"),
      desc: L("Now playing, media keys and volume sliders for the PC and Spotify."),
      buttons: [
        btn(0, 0, L(""), null, null, { dynamicType: "now_playing", columnSpan: 2, rowSpan: 2 }),
        btn(0, 2, PREV, "arrow_back", act("media", { command: "previous" })),
        btn(0, 3, PLAY, "play", act("media", { command: "playpause" }), { backgroundColor: GREEN }),
        btn(0, 4, L("Volume"), null, null, { dynamicType: "volume_slider", dynamicParameters: { target: "output" }, rowSpan: 3 }),
        btn(1, 2, NEXT, "playlist_play", act("media", { command: "next" })),
        btn(1, 3, L("Mute"), "volume_off", act("mixer", { operation: "toggleMute", deviceId: "default" })),
        btn(2, 0, L("Spotify"), null, null, { dynamicType: "volume_slider", dynamicParameters: { target: "app", app: "Spotify" }, columnSpan: 4 }),
      ],
    },
    {
      key: "productivity",
      name: L("Productivity"),
      desc: L("Windows shortcuts, copy and paste, a pomodoro, clock and PC monitors."),
      buttons: [
        btn(0, 0, L("Desktop"), "computer", act("hotkey", { keys: "#d" })),
        btn(0, 1, L("Files"), "folder", act("hotkey", { keys: "#e" })),
        btn(0, 2, L("History"), "web_asset", act("hotkey", { keys: "#v" })),
        btn(0, 3, L("Snip"), "camera", act("hotkey", { keys: "#+s" })),
        btn(0, 4, L("Tasks"), "tune", act("hotkey", { keys: "^+{ESC}" })),
        btn(1, 0, L("Copy"), "keyboard", act("hotkey", { keys: "^c" })),
        btn(1, 1, L("Paste"), "keyboard", act("hotkey", { keys: "^v" })),
        btn(1, 2, L("Undo"), "keyboard", act("hotkey", { keys: "^z" })),
        btn(1, 3, L("Pomodoro"), "timer", act("timer", { mode: "pomodoro", workMin: "25", breakMin: "5", operation: "toggle" }), { columnSpan: 2 }),
        btn(2, 0, CLOCK, null, null, { dynamicType: "clock" }),
        btn(2, 1, L("CPU"), null, null, { dynamicType: "cpu_monitor" }),
        btn(2, 2, L("RAM"), null, null, { dynamicType: "memory_monitor" }),
        btn(2, 3, LOCK, "lock", act("windows", { operation: "lock" })),
        btn(2, 4, L("Sleep"), "power_off", act("windows", { operation: "sleep" }), { backgroundColor: RED }),
      ],
    },
    {
      key: "gaming",
      name: L("Gaming"),
      desc: L("Live CPU/GPU/RAM, Discord, instant replay, screenshot and volume sliders."),
      buttons: [
        btn(0, 0, L("CPU"), null, null, { dynamicType: "cpu_monitor" }),
        btn(0, 1, L("GPU"), null, null, { dynamicType: "gpu_monitor" }),
        btn(0, 2, L("RAM"), null, null, { dynamicType: "memory_monitor" }),
        btn(0, 3, L("Net"), null, null, { dynamicType: "network_monitor" }),
        btn(0, 4, L("Game"), null, null, { dynamicType: "volume_slider", dynamicParameters: { target: "output" }, rowSpan: 3 }),
        btn(1, 0, MIC, "mic", act("discord", { operation: "toggleMute" }), { backgroundColor: PURPLE }),
        btn(1, 1, DEAF, "headphones", act("discord", { operation: "toggleDeafen" }), { backgroundColor: PURPLE }),
        btn(1, 2, CLIP, "save", act("obs", { operation: "saveReplay" }), { backgroundColor: RED }),
        btn(1, 3, L("Screenshot"), "camera", act("hotkey", { keys: "#%{PRTSC}" })),
        btn(2, 0, L("Discord"), null, null, { dynamicType: "volume_slider", dynamicParameters: { target: "app", app: "Discord" }, columnSpan: 2 }),
        btn(2, 2, PLAY, "play", act("media", { command: "playpause" }), { backgroundColor: GREEN }),
        btn(2, 3, NEXT, "playlist_play", act("media", { command: "next" })),
      ],
    },
  ];

  // Perfis no idioma pedido, no formato que o DeckOS importa.
  function build(lang) {
    const pick = v => (v && typeof v === "object" ? v[lang] ?? v.en : v);
    return PROFILES.map(p => ({
      key: p.key,
      desc: pick(p.desc),
      profile: {
        name: pick(p.name),
        buttons: p.buttons.map(b => {
          const out = { ...b, label: pick(b.label) };
          if (b.activeLabel) out.activeLabel = pick(b.activeLabel);
          return out;
        }),
      },
    }));
  }

  window.DDProfiles = { build };
})();
