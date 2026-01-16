package com.yc.pm;

import android.content.pm.PackageInfo;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.IInterface;

import java.lang.reflect.Method;

import app.revanced.extension.kakaotalk.spoofer.Spoofer;

/**
 * Created by yanchen on 18-1-28.
 */

public class WebViewUpdateServiceStub extends MethodInvocationProxy<MethodInvocationStub<IInterface>> {
    private static String WEBVIEW_UPDATE_SERVICE_NAME = "webviewupdate";

    public WebViewUpdateServiceStub() {
        super(new MethodInvocationStub<>(getInterface()));
        init();

    }

    public static void replaceService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                WebViewUpdateServiceStub serviceStub = new WebViewUpdateServiceStub();
            } catch (Exception e) {

            }
        }
    }

    private static IInterface getInterface() {
        Object service = Reflect.on("android.os.ServiceManager").call("getService", WEBVIEW_UPDATE_SERVICE_NAME).get();

        IInterface asInterface = Reflect.on("android.webkit.IWebViewUpdateService$Stub").call("asInterface", service)
                .get();
        return asInterface;
    }

    private static IBinder getBinder() {
        return Reflect.on("android.os.ServiceManager").call("getService", WEBVIEW_UPDATE_SERVICE_NAME).get();
    }

    private void init() {
        addMethodProxy(new WaitForAndGetProvider());

        getBinder();
        BinderInvocationStub pmHookBinder = new BinderInvocationStub(getInvocationStub().getBaseInterface());
        pmHookBinder.copyMethodProxies(getInvocationStub());
        pmHookBinder.replaceService(WEBVIEW_UPDATE_SERVICE_NAME);
    }

    private static class WaitForAndGetProvider extends MethodProxy {
        @Override
        public String getMethodName() {
            return "waitForAndGetProvider";
        }

        @Override
        public Object call(Object who, Method method, Object... args) throws Throwable {
            Object result = method.invoke(who, args);
            if (result != null) {
                PackageInfo inf = Reflect.on(result).get("packageInfo");
                if (inf != null) {
                    String packageName = Reflect.on(inf).get("packageName");

                    // WebView 프로바이더 (com.google.android.webview, com.android.webview 등)는 스푸핑하지 않음
                    // 카카오톡 패키지만 스푸핑
                    boolean isKakaoTalk = packageName != null &&
                            (packageName.equals("com.kakao.talk") || packageName.equals(Spoofer.PACKAGE_NAME));

                    if (isKakaoTalk) {
                        Signature[] sigs = Reflect.on(inf).get("signatures");
                        if (sigs != null) {
                            Spoofer.replaceSignature(sigs);
                        }

                        SigningInfo signingInfo = Reflect.on(inf).get("signingInfo");
                        if (signingInfo != null) {
                            Object mSigningDetails = Reflect.on(signingInfo).get("mSigningDetails");
                            Object mSignatures = Reflect.on(mSigningDetails).get("mSignatures");
                            if (mSignatures != null && mSignatures.getClass().isArray()) {
                                Signature[] sigs2 = (Signature[]) mSignatures;
                                Spoofer.replaceSignature(sigs2);
                            }
                        }

                        if (!packageName.contains("android")) {
                            Reflect.on(inf).set("packageName", Spoofer.PACKAGE_NAME);
                        }
                    }
                    // WebView 프로바이더 등 다른 패키지는 원본 정보 그대로 반환
                }
            }
            return result;
        }
    }
}
