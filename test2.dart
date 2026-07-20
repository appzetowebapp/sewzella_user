import 'package:flutter_inappwebview/flutter_inappwebview.dart';
void main() {
  InAppWebView(
    androidOnShowFileChooser: (controller, request) async {
      return null;
    },
  );
}
