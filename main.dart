import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const EyeApp());

class EyeApp extends StatelessWidget {
  const EyeApp({super.key});
  @override
  Widget build(BuildContext context) {
      return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: EyePage(),
    );
  }
}

class EyePage extends StatefulWidget {
  const EyePage({super.key});
  @override
  State<EyePage> createState() => _EyePageState();
}

enum Phase { calibrate, run }

class _EyePageState extends State<EyePage> {
  // Native channel -> returns {"x": 0..1, "y": 0..1}
  static const _ch = MethodChannel('eye_tracker');

  // Poll at 20 Hz
  static const _poll = Duration(milliseconds: 50);

  Phase _phase = Phase.calibrate;

  // Latest raw (uncalibrated) sample from native
  double _nx = 0.5, _ny = 0.5;

  // Calibration mapping X_cal = ax*nx + bx; Y_cal = ay*ny + by
  double _ax = 1.0, _bx = 0.0, _ay = 1.0, _by = 0.0;

  Timer? _timer;

  // ----- Calibration state -----
  // 9 target points (normalized positions)
  final List<Offset> _targets = const [
    // Row: center, mid-right, top-right, top-mid, top-left, mid-left, bottom-left, bottom-mid, bottom-right
    Offset(0.5, 0.5), // center
    Offset(0.9, 0.5), // middle right
    Offset(0.9, 0.1), // top right
    Offset(0.5, 0.1), // top middle
    Offset(0.1, 0.1), // top left
    Offset(0.1, 0.5), // middle left
    Offset(0.1, 0.9), // bottom left
    Offset(0.5, 0.9), // bottom middle
    Offset(0.9, 0.9), // bottom right
  ];

  int _idx = 0;                    // which target we’re on
  DateTime _stepStart = DateTime.now();
  final List<Offset> _measured = []; // averaged raw gaze per target
  final List<Offset> _targetUsed = []; // record of target coords (normalized)

  @override
  void initState() {
    super.initState();
    _stepStart = DateTime.now();
    _timer = Timer.periodic(_poll, (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _pullGaze() async {
    try {
      final m = await _ch.invokeMethod<Map>('getGaze');
      if (m == null) return;
      final x = (m['x'] as num?)?.toDouble();
      final y = (m['y'] as num?)?.toDouble();
      if (x == null || y == null) return;
      _nx = x.clamp(0.0, 1.0);
      _ny = y.clamp(0.0, 1.0);
    } catch (_) {
      // ignore if native not ready
    }
  }

  // Per-step sample buffer (we only keep for the current target)
  final List<Offset> _samples = [];

  Future<void> _tick() async {
    await _pullGaze();

    if (_phase == Phase.calibrate) {
      final elapsed = DateTime.now().difference(_stepStart);
      // first 1s = ignore to allow eye to settle
      if (elapsed.inMilliseconds >= 1000 && elapsed.inMilliseconds < 5000) {
        _samples.add(Offset(_nx, _ny));
      }

      // after 5s -> compute average, advance to next target
      if (elapsed.inMilliseconds >= 5000) {
        // average samples (fallback to last reading if empty)
        Offset avg;
        if (_samples.isEmpty) {
          avg = Offset(_nx, _ny);
        } else {
          double sx = 0, sy = 0;
          for (final s in _samples) {
            sx += s.dx; sy += s.dy;
          }
          avg = Offset(sx / _samples.length, sy / _samples.length);
        }
        _measured.add(avg);
        _targetUsed.add(_targets[_idx]);

        _idx++;
        _samples.clear();
        _stepStart = DateTime.now();

        if (_idx >= _targets.length) {
          _computeCalibration();
          setState(() => _phase = Phase.run);
        } else {
          setState(() {}); // advance dot
        }
      } else {
        // keep painting dot
        if (mounted) setState(() {});
      }
    } else {
      // Run phase: just repaint with calibrated point
      if (mounted) setState(() {});
    }
  }

  void _computeCalibration() {
    // Independent least-squares fit:
    //   X_target = ax * nx_measured + bx
    //   Y_target = ay * ny_measured + by
    // Using all 9 averaged samples.
    double mean(List<double> v) => v.isEmpty ? 0 : v.reduce((a,b)=>a+b)/v.length;

    List<double> xm = _measured.map((o)=>o.dx).toList();
    List<double> ym = _measured.map((o)=>o.dy).toList();
    List<double> xt = _targetUsed.map((o)=>o.dx).toList();
    List<double> yt = _targetUsed.map((o)=>o.dy).toList();

    double mx = mean(xm), my = mean(ym), mxt = mean(xt), myt = mean(yt);

    double varX = xm.fold(0.0, (s,x)=> s + (x-mx)*(x-mx));
    double varY = ym.fold(0.0, (s,y)=> s + (y-my)*(y-my));
    double covX = 0.0, covY = 0.0;
    for (int i=0;i<xm.length;i++) {
      covX += (xm[i]-mx)*(xt[i]-mxt);
      covY += (ym[i]-my)*(yt[i]-myt);
    }

    _ax = (varX.abs() < 1e-9) ? 1.0 : (covX/varX);
    _bx = mxt - _ax*mx;
    _ay = (varY.abs() < 1e-9) ? 1.0 : (covY/varY);
    _by = myt - _ay*my;
  }

  // Apply calibration and clamp to [0,1]
  Offset _applyCal(double nx, double ny) {
    final x = (_ax*nx + _bx).clamp(0.0, 1.0);
    final y = (_ay*ny + _by).clamp(0.0, 1.0);
    return Offset(x, y);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            // Pick what to draw depending on phase
            if (_phase == Phase.calibrate) {
              final target = _targets[_idx];
              final px = target.dx * c.maxWidth;
              final py = target.dy * c.maxHeight;

              // progress text
              final step = _idx + 1;
              final elapsed = DateTime.now().difference(_stepStart);
              final secs = (max(0, 5 - elapsed.inSeconds));
              final collecting = elapsed.inMilliseconds >= 1000;

              return Stack(
                children: [
                  Positioned.fill(child: Container(color: Colors.black)),
                  Positioned(
                    left: px - 10,
                    top: py - 10,
                    child: Container(
                      width: 20, height: 20,
                      decoration: const BoxDecoration(
                        color: Colors.orange, shape: BoxShape.circle),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Calibration $step/9 • ${collecting ? "collecting" : "get ready"} • ${secs}s',
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ),
                ],
              );
            } else {
              // RUN: show calibrated dot + pixel coords
              final cal = _applyCal(_nx, _ny);
              final px = cal.dx * c.maxWidth;
              final py = cal.dy * c.maxHeight;

              return Stack(
                children: [
                  Positioned.fill(child: Container(color: Colors.black)),
                  Positioned(
                    left: px - 6, top: py - 6,
                    child: Container(
                      width: 12, height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '(${px.toStringAsFixed(0)}, ${py.toStringAsFixed(0)})',
                        style: const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    ),
                  ),
                ],
              );
            }
          },
        ),
      ),
    );
  }
}
