import 'package:flutter/material.dart';

const ink = Color(0xFF203B31);
const forest = Color(0xFF234D3C);
const paper = Color(0xFFF7F6F0);
const lime = Color(0xFFDFECAC);
const pale = Color(0xFFEEF1E6);
const muted = Color(0xFF69756C);
const border = Color(0xFFE2E6DB);
const heading = TextStyle(
  fontSize: 27,
  height: 1.4,
  fontWeight: FontWeight.w700,
  color: ink,
);
const secondary = TextStyle(fontSize: 13, height: 1.6, color: muted);
const roleIcons = [
  Icons.school_outlined,
  Icons.work_outline,
  Icons.laptop_mac,
  Icons.flag_outlined,
  Icons.home_outlined,
  Icons.local_cafe_outlined,
  Icons.wb_sunny_outlined,
  Icons.more_horiz,
];
String formatDate(DateTime date) =>
    '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color = pale});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        color: forest,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

class IconLabel extends StatelessWidget {
  const IconLabel(this.icon, this.text, {super.key});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: muted),
      const SizedBox(width: 6),
      Flexible(
        child: Text(text, style: const TextStyle(color: muted, fontSize: 11)),
      ),
    ],
  );
}

class Notice extends StatelessWidget {
  const Notice({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
  });
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: pale,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: forest, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 12,
                  color: muted,
                  height: 1.65,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
Future<void> info(BuildContext context, String title, String message) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );

class BotanicalScene extends StatelessWidget {
  const BotanicalScene({super.key, required this.height});
  final double height;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _BotanicalPainter()),
    ),
  );
}

class _BotanicalPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 340, size.height / 180);
    final brush = Paint();
    void rect(Rect r, Color c, double radius) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, Radius.circular(radius)),
        brush
          ..color = c
          ..style = PaintingStyle.fill,
      );
    }

    rect(const Rect.fromLTWH(0, 0, 340, 180), const Color(0xFFEAEDE0), 0);
    canvas.drawCircle(
      const Offset(268, 42),
      37,
      brush..color = const Color(0xFFE6C77F),
    );
    rect(const Rect.fromLTWH(95, 16, 134, 180), const Color(0xFFCEDAC2), 67);
    rect(const Rect.fromLTWH(108, 29, 108, 170), const Color(0xFFAEC5AD), 54);
    brush
      ..color = paper
      ..strokeWidth = 2;
    canvas.drawLine(const Offset(162, 30), const Offset(162, 180), brush);
    canvas.drawLine(const Offset(108, 104), const Offset(216, 104), brush);
    canvas.drawPath(
      Path()
        ..moveTo(0, 167)
        ..lineTo(340, 150)
        ..lineTo(340, 180)
        ..lineTo(0, 180)
        ..close(),
      brush..color = const Color(0xFFD7DDCA),
    );
    brush
      ..color = forest
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(264, 165)
        ..quadraticBezierTo(254, 110, 286, 43),
      brush,
    );
    void leaf(double x, double y, double angle, Color color, double scale) {
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      canvas.scale(scale);
      canvas.drawPath(
        Path()
          ..moveTo(0, 30)
          ..quadraticBezierTo(-5, 0, 30, 0)
          ..quadraticBezierTo(35, 32, 0, 30)
          ..close(),
        brush
          ..color = color
          ..style = PaintingStyle.fill,
      );
      canvas.drawLine(
        const Offset(1, 29),
        const Offset(25, 5),
        brush
          ..color = paper.withValues(alpha: 0.6)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
      canvas.restore();
    }

    leaf(250, 101, -0.4, const Color(0xFF447359), 1.3);
    leaf(273, 65, 0.25, const Color(0xFF698865), 1);
    leaf(243, 140, -1.3, const Color(0xFF2F5C47), 1.1);
    canvas.drawPath(
      Path()
        ..moveTo(232, 143)
        ..lineTo(288, 143)
        ..lineTo(279, 180)
        ..lineTo(241, 180)
        ..close(),
      brush
        ..color = const Color(0xFFCD8365)
        ..style = PaintingStyle.fill,
    );
    rect(const Rect.fromLTWH(26, 99, 53, 66), const Color(0xFFE4DDBF), 8);
    leaf(40, 113, -0.35, const Color(0xFF608060), 0.95);
    rect(const Rect.fromLTWH(21, 164, 64, 6), const Color(0xFFCD8365), 2);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
