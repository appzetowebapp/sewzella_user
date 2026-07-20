import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

void main() {
  InAppWebView(
    onShowFileChooser: (controller, request) async {
      print(request.runtimeType);
      return null;
    },
  );
}
