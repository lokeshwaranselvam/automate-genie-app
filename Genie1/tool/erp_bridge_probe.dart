import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:homegenie/utils/platform/erp_webview_web.dart';
@JS('genieBridgeProbeState') external set result(JSAny? value);
void main() => runApp(const MaterialApp(home: Probe()));
class Probe extends StatefulWidget {
 const Probe({super.key});
 @override State<Probe> createState()=>ProbeState();
}
class ProbeState extends State<Probe> {
 final controller=WebViewController();
 final messages=<String>[];
 bool early=false,blocked=false;
 int refreshes=0;
 void publish()=>result = {'earlyBridge':early,'crossOriginBlocked':blocked,'messages':messages,'refreshes':refreshes}.jsify();
 @override void initState(){super.initState();unawaited(start());}
 Future<void> start()async {
 controller.onPullToRefresh=() async {refreshes++;publish();};
 await controller.addJavaScriptChannel('GenieExpenseClaim',onMessageReceived:(message){messages.add(message.message);publish();});
 await controller.setNavigationDelegate(NavigationDelegate(
  onNavigationRequest:(_)=>NavigationDecision.navigate,
  onPageFinished:(_)async{
   early=await controller.runJavaScriptReturningResult("document.body.dataset.early === 'true'")==true;
   await controller.runJavaScript("GenieExpenseClaim.postMessage('echo');");publish();
  },
  onWebResourceError:(error){result = {'error':error.description}.jsify();},
 ));
 try{await controller.loadRequest(Uri.parse('https://outside.example/'));}catch(_){blocked=true;}
 await controller.loadRequest(Uri.base.resolve('/pages/probe-frame.html'));
 if(mounted)setState((){});
 }
 @override Widget build(BuildContext context)=>Scaffold(body:WebViewWidget(controller:controller));
}
