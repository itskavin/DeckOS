import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'home_controller.dart';

/// Um dispositivo de áudio (saída OU entrada) no molde do Control Center: cabeçalho com o
/// nome e o mudo, e uma fileira de controles verticais — o volume geral e um por app,
/// com o ícone do app embaixo (tocar no ícone muta o app).
class MixerDeviceCard extends StatelessWidget {
  final MixerEntity item;
  final HomeController controller;
  final bool isInput;

  const MixerDeviceCard({
    super.key,
    required this.item,
    required this.controller,
    required this.isInput,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final device = item.device;
    final channels = device.channels ?? [];
    final fallback = isInput ? Icons.mic_rounded : Icons.volume_up_rounded;
    final title = device.title ?? item.id ?? tr('Desconhecido');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppleSpacing.md, vertical: 6),
      padding: const EdgeInsets.fromLTRB(
          AppleSpacing.md, AppleSpacing.sm, AppleSpacing.xs, AppleSpacing.md),
      decoration: BoxDecoration(
        color: c.secondaryGroupedBackground,
        borderRadius: BorderRadius.circular(AppleRadii.lg),
        border: Border.all(color: c.separator, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _AppIcon(base64: device.icon, fallback: fallback, size: 30),
              const SizedBox(width: AppleSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.headline.copyWith(color: c.label)),
                    Text(
                      channels.isEmpty
                          ? tr('Nenhum app reproduzindo áudio')
                          : tr('{n} apps', {'n': channels.length}),
                      style: type.footnote.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
              _RoundToggle(
                on: device.mute,
                icon: device.mute
                    ? (isInput ? Icons.mic_off_rounded : Icons.volume_off_rounded)
                    : fallback,
                label: device.mute ? tr('Ativar som') : tr('Mutar'),
                onTap: () => controller.toggleMute(item.id!, device.mute, isInput: isInput),
              ),
            ],
          ),
          const SizedBox(height: AppleSpacing.md),
          SizedBox(
            height: 214,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _MixerColumn(
                  label: tr('Geral'),
                  icon: _AppIcon(base64: null, fallback: fallback, size: 28),
                  volume: device.volume,
                  muted: device.mute,
                  isInput: isInput,
                  onChanged: (v) => controller.setVolume(item.id!, v, isInput: isInput),
                  onToggleMute: () =>
                      controller.toggleMute(item.id!, device.mute, isInput: isInput),
                ),
                if (channels.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 6),
                    child: VerticalDivider(width: 1, color: c.separator),
                  ),
                for (final ch in channels)
                  _MixerColumn(
                    label: _appName(ch.description) ?? 'App ${ch.id}',
                    icon: _AppIcon(base64: ch.icon, fallback: Icons.apps_rounded, size: 28),
                    volume: ch.volume,
                    muted: ch.mute,
                    isInput: isInput,
                    onChanged: (v) => controller.setChannelVolume(item.id!, ch.id, v),
                    onToggleMute: () =>
                        controller.toggleChannelMute(item.id!, ch.id, ch.mute),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "Spotify: Música" → "Spotify".
  static String? _appName(String? d) {
    if (d == null || d.isEmpty) return null;
    return d.contains(':') ? d.split(':').first.trim() : d;
  }
}

/// Um controle vertical com o ícone e o nome embaixo.
class _MixerColumn extends StatelessWidget {
  const _MixerColumn({
    required this.label,
    required this.icon,
    required this.volume,
    required this.muted,
    required this.isInput,
    required this.onChanged,
    required this.onToggleMute,
  });

  final String label;
  final Widget icon;
  final int volume;
  final bool muted;
  final bool isInput;
  final ValueChanged<int> onChanged;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return SizedBox(
      width: 72,
      child: Column(
        children: [
          ControlCenterSlider(
            value: volume,
            muted: muted,
            isInput: isInput,
            onChanged: onChanged,
            semanticLabel: label,
          ),
          const SizedBox(height: AppleSpacing.xs),
          Semantics(
            button: true,
            toggled: muted,
            label: muted ? tr('Ativar som') : tr('Mutar'),
            child: ApplePressable(
              onTap: onToggleMute,
              pressedScale: 0.88,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedOpacity(
                    opacity: muted ? 0.4 : 1,
                    duration: AppleMotion.of(context, AppleMotion.normal),
                    child: icon,
                  ),
                  if (muted)
                    Positioned(
                      right: -5,
                      bottom: -3,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: c.red, shape: BoxShape.circle),
                        child: const Icon(Icons.volume_off_rounded,
                            size: 10, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: type.caption2.copyWith(color: c.secondaryLabel)),
        ],
      ),
    );
  }
}

/// Controle de volume vertical do Control Center: cápsula alta, nível preenchido de baixo
/// para cima, o glifo do alto-falante muda com o nível. Arrastar é relativo ao ponto de
/// partida (como no iPhone); manda ao PC no máximo ~12 vezes por segundo.
class ControlCenterSlider extends StatefulWidget {
  const ControlCenterSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.muted = false,
    this.isInput = false,
    this.height = 150,
    this.width = 58,
    this.semanticLabel,
  });

  /// 0 a 100.
  final int value;
  final ValueChanged<int> onChanged;
  final bool muted;
  final bool isInput;
  final double height;
  final double width;
  final String? semanticLabel;

  @override
  State<ControlCenterSlider> createState() => _ControlCenterSliderState();
}

class _ControlCenterSliderState extends State<ControlCenterSlider> {
  late double _value = widget.value.toDouble();
  bool _dragging = false;
  Timer? _send;
  int? _pending;

  @override
  void didUpdateWidget(ControlCenterSlider old) {
    super.didUpdateWidget(old);
    // O valor do PC só vale quando o dedo não está em cima.
    if (!_dragging && old.value != widget.value) _value = widget.value.toDouble();
  }

  @override
  void dispose() {
    _send?.cancel();
    super.dispose();
  }

  void _emit(int v) {
    _pending = v;
    if (_send?.isActive ?? false) return;
    _flush();
    _send = Timer(const Duration(milliseconds: 80), _flush);
  }

  void _flush() {
    final v = _pending;
    _pending = null;
    if (v != null) widget.onChanged(v);
  }

  void _drag(double dy) {
    final before = _value;
    final next = (_value - dy / widget.height * 100).clamp(0.0, 100.0);
    if (next == _value) return;
    setState(() => _value = next);
    // Bate no fim da escala: um toque leve, como no iPhone.
    if ((next == 0 || next == 100) && before != next) ThemeController.instance.tapFeedback();
    _emit(next.round());
  }

  IconData get _glyph {
    final v = _value;
    if (widget.isInput) {
      return widget.muted || v == 0 ? Icons.mic_off_rounded : Icons.mic_rounded;
    }
    if (widget.muted || v == 0) return Icons.volume_off_rounded;
    if (v < 34) return Icons.volume_mute_rounded;
    if (v < 67) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = widget.muted ? c.gray : (dark ? Colors.white : c.accent);
    final onFill = AppleColors.onColor(fill);
    final f = _value / 100;
    final radius = widget.width * 0.38;

    Widget face(Color ink) => Column(
          children: [
            const SizedBox(height: 10),
            Text('${_value.round()}',
                style: type.footnote.copyWith(
                    color: ink.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const Spacer(),
            Icon(_glyph, color: ink, size: 22),
            const SizedBox(height: 14),
          ],
        );

    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: '${_value.round()}%',
      increasedValue: '${(_value + 10).clamp(0, 100).round()}%',
      decreasedValue: '${(_value - 10).clamp(0, 100).round()}%',
      onIncrease: () => widget.onChanged((_value = (_value + 10).clamp(0, 100)).round()),
      onDecrease: () => widget.onChanged((_value = (_value - 10).clamp(0, 100)).round()),
      child: GestureDetector(
        onVerticalDragStart: (_) => setState(() => _dragging = true),
        onVerticalDragUpdate: (d) => _drag(d.delta.dy),
        onVerticalDragEnd: (_) {
          setState(() => _dragging = false);
          _send?.cancel();
          _flush();
        },
        child: AnimatedScale(
          // Segurando, o controle cresce um pouco, como no Control Center.
          scale: _dragging ? 1.04 : 1,
          duration: AppleMotion.of(context, AppleMotion.fast),
          curve: AppleMotion.snappy,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(radius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: c.tertiaryFill),
                  face(c.label),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: f),
                    duration: _dragging ? Duration.zero : AppleMotion.of(context, AppleMotion.normal),
                    curve: AppleMotion.smooth,
                    builder: (context, t, _) => ClipRect(
                      clipper: _FromBottom(t),
                      child: ColoredBox(color: fill, child: face(onFill)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FromBottom extends CustomClipper<Rect> {
  _FromBottom(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, size.height * (1 - fraction.clamp(0.0, 1.0)), size.width, size.height);

  @override
  bool shouldReclip(_FromBottom old) => old.fraction != fraction;
}

/// Botão redondo de liga/desliga (os do Control Center): vermelho quando mudo.
class _RoundToggle extends StatelessWidget {
  const _RoundToggle({
    required this.on,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool on;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Semantics(
      button: true,
      toggled: on,
      label: label,
      child: ApplePressable(
        onTap: onTap,
        pressedScale: 0.9,
        child: Padding(
          padding: const EdgeInsets.all(AppleSpacing.xs),
          child: AnimatedContainer(
            duration: AppleMotion.of(context, AppleMotion.normal),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? c.red : c.tertiaryFill,
            ),
            child: Icon(icon, size: 18, color: on ? Colors.white : c.label),
          ),
        ),
      ),
    );
  }
}

/// Ícone do app (ou do dispositivo) que o PC manda, recortado em squircle; sem ele, o
/// glifo.
class _AppIcon extends StatefulWidget {
  const _AppIcon({required this.base64, required this.fallback, this.size = 28});

  final String? base64;
  final IconData fallback;
  final double size;

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  Uint8List? _bytes;
  String? _source;

  Uint8List? get _decoded {
    final raw = widget.base64;
    if (raw == _source) return _bytes;
    _source = raw;
    _bytes = null;
    if (raw != null && raw.isNotEmpty) {
      try {
        _bytes = base64Decode(raw.startsWith('data:') ? raw.split(',')[1] : raw);
      } catch (_) {}
    }
    return _bytes;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final s = widget.size;
    final bytes = _decoded;
    final glyph = Container(
      width: s,
      height: s,
      decoration: ShapeDecoration(
        color: c.tertiaryFill,
        shape: AppleShapes.squircle(AppleShapes.tileRadius(s)),
      ),
      child: Icon(widget.fallback, size: s * 0.55, color: c.secondaryLabel),
    );
    if (bytes == null) return glyph;
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(AppleShapes.tileRadius(s)),
      child: Image.memory(bytes,
          width: s,
          height: s,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => glyph),
    );
  }
}

/// Lista rolável de dispositivos (um lado do split, no modo deitado).
class MixerList extends StatelessWidget {
  final List<MixerEntity> devices;
  final HomeController controller;
  final bool isInput;
  final Future<void> Function() onRefresh;

  const MixerList({
    super.key,
    required this.devices,
    required this.controller,
    required this.isInput,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator.adaptive(
      onRefresh: onRefresh,
      child: devices.isEmpty
          ? ListView(
              children: [
                EmptyState(
                  icon: isInput ? Icons.mic_off_rounded : Icons.volume_off_rounded,
                  title: isInput
                      ? tr('Nenhum dispositivo de entrada encontrado.')
                      : tr('Nenhum dispositivo de saída encontrado.'),
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: devices.length,
              itemBuilder: (context, index) => MixerDeviceCard(
                item: devices[index],
                controller: controller,
                isInput: isInput,
              ),
            ),
    );
  }
}

/// Espera da primeira leitura do mixer.
class MixerLoading extends StatelessWidget {
  const MixerLoading({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: AppleColors.of(context).secondaryLabel,
          ),
        ),
      );
}
