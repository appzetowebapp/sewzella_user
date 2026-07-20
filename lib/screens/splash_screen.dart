import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_master_app/config/app_config.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  
  late Animation<double> _blobScale;      
  late Animation<double> _screenSpread;  
  late Animation<double> _logoOpacity;   
  late Animation<double> _loaderOpacity; 

  @override
  void initState() {
    super.initState();
    // Hide status bar during splash screen (keeps bottom nav bar if present)
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.bottom]);
    _setupSuperSmoothAnimations();
  }

  void _setupSuperSmoothAnimations() {
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 2400),
      vsync: this,
    );

    _blobScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.38, curve: Curves.easeOutBack), 
      ),
    );

    _screenSpread = Tween<double>(begin: 1.0, end: 16.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.45, 0.85, curve: Curves.easeInOutCubic), 
      ),
    );

    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.15, 0.48, curve: Curves.easeIn),
      ),
    );

    _loaderOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.75, 1.0, curve: Curves.easeIn),
      ),
    );

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    // Restore status bar and permanently lock into edge-to-edge mode ONLY on Android 15+.
    // On Android 10-14, we use manual mode so the OS natively renders the teal status bar.
    if (AppConfig.androidSdkInt >= 35) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    super.dispose();
  }

  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, 
      body: Stack(
        alignment: Alignment.center,
        children: [
          
          // 1. Redesigned Premium Hand-crafted Amoeba Shape
          AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              double currentScale = _blobScale.value * _screenSpread.value;

              return Transform.scale(
                scale: currentScale,
                child: ClipPath(
                  clipper: PerfectAmoebaClipper(),
                  child: Container(
                    width: 480,  
                    height: 480, 
                    color: const Color(0xFF8E4692),
                  ),
                ),
              );
            },
          ),

          // 2. Premium Logo Component
          AnimatedBuilder(
            animation: _logoOpacity,
            builder: (context, child) {
              return Opacity(
                opacity: _logoOpacity.value,
                child: Center(
                  child: SizedBox(
                    width: 270, 
                    height: 270,
                    child: Image.asset(
                      AppConfig.appLogoPath,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              );
            },
          ),

          // 3. Bottom Loader Dots Matrix
          Positioned(
            bottom: 65,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedBuilder(
                animation: _loaderOpacity,
                builder: (context, child) {
                  return Opacity(
                    opacity: _loaderOpacity.value, 
                    child: const VideoStyleDotLoader(),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom Clipper utilizing precise control vectors to map a fluid, smooth amoebic structure
class PerfectAmoebaClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    final w = size.width;
    final h = size.height;

    // Start at a smooth dip on the top side
    path.moveTo(w * 0.50, h * 0.25);

    // Top-right smooth protrusion
    path.cubicTo(w * 0.60, h * 0.15, w * 0.75, h * 0.10, w * 0.82, h * 0.25);
    path.cubicTo(w * 0.88, h * 0.38, w * 0.72, h * 0.48, w * 0.85, h * 0.55);

    // Mid-right fluid extension
    path.cubicTo(w * 0.98, h * 0.62, w * 0.95, h * 0.78, w * 0.78, h * 0.82);

    // Bottom asymmetric elongated pseudopodia lobe
    path.cubicTo(w * 0.65, h * 0.85, w * 0.55, h * 0.98, w * 0.42, h * 0.90);
    path.cubicTo(w * 0.32, h * 0.82, w * 0.35, h * 0.70, w * 0.22, h * 0.72);

    // Bottom-left wide organic curve
    path.cubicTo(w * 0.08, h * 0.75, w * 0.02, h * 0.55, w * 0.15, h * 0.45);

    // Upper-left smooth arm wrapping back around the logo area
    path.cubicTo(w * 0.25, h * 0.38, w * 0.12, h * 0.20, w * 0.32, h * 0.22);
    path.cubicTo(w * 0.42, h * 0.24, w * 0.45, h * 0.30, w * 0.50, h * 0.25);

    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class VideoStyleDotLoader extends StatefulWidget {
  const VideoStyleDotLoader({super.key});

  @override
  State<VideoStyleDotLoader> createState() => _VideoStyleDotLoaderState();
}

class _VideoStyleDotLoaderState extends State<VideoStyleDotLoader> with SingleTickerProviderStateMixin {
  late AnimationController _dotController;

  @override
  void initState() {
    super.initState();
    _dotController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _dotController,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            double delay = index * 0.2;
            double progress = (_dotController.value - delay);
            if (progress < 0) progress += 1.0;

            double scaleOpacity = Curves.easeInOut.transform(
              progress <= 0.5 ? progress * 2 : (1.0 - progress) * 2,
            );

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 5.0),
              width: 5.5,
              height: 5.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.25 + (scaleOpacity * 0.75)),
              ),
            );
          }),
        );
      },
    );
  }
}