import pathlib
import sys

engine = pathlib.Path(sys.argv[1])


def patch(relative_path, replacements):
    path = engine / relative_path
    text = path.read_text()
    for original, replacement in replacements:
        if original not in text:
            raise SystemExit(f"Patch target not found in {relative_path}: {original[:80]!r}")
        text = text.replace(original, replacement, 1)
    path.write_text(text)


patch("Natives/input_bridge_v3.m", [
    (
        "void sendData(short type, int i1, int i2, short i3, short i4) {",
        "void (*FCL_inputHook)(int type, int i1, int i2, int i3, int i4, double f1, double f2) = NULL;\n\n"
        "void sendData(short type, int i1, int i2, short i3, short i4) {",
    ),
    (
        "BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */) {\n",
        "BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */) {\n"
        "    if (FCL_inputHook) {\n"
        "        FCL_inputHook(1, codepoint, 0, 0, 0, 0, 0);\n"
        "        return YES;\n"
        "    }\n",
    ),
    (
        "BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods) {\n",
        "BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods) {\n"
        "    if (FCL_inputHook) {\n"
        "        return YES;\n"
        "    }\n",
    ),
    (
        "    if (!GLFW_invoke_CursorPos || !isInputReady) return;\n",
        "    if ((!GLFW_invoke_CursorPos && !FCL_inputHook) || !isInputReady) return;\n",
    ),
    (
        "    if (!isUseStackQueueCall) {\n        GLFW_invoke_CursorPos((void*) showingWindow, (double) cursorX, (double) cursorY);\n    }",
        "    if (FCL_inputHook) {\n"
        "        FCL_inputHook(3, 0, 0, 0, 0, cursorX, cursorY);\n"
        "        return;\n"
        "    }\n"
        "    if (!isUseStackQueueCall) {\n        GLFW_invoke_CursorPos((void*) showingWindow, (double) cursorX, (double) cursorY);\n    }",
    ),
    (
        "void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {\n",
        "void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {\n"
        "    if (FCL_inputHook) {\n"
        "        FCL_inputHook(2, key, scancode, action, mods, 0, 0);\n"
        "        return;\n"
        "    }\n",
    ),
    (
        "void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {\n",
        "void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {\n"
        "    if (FCL_inputHook) {\n"
        "        if (button >= 0) FCL_inputHook(4, button, action, mods, 0, cursorX, cursorY);\n"
        "        return;\n"
        "    }\n",
    ),
    (
        "    windowWidth = width;\n    windowHeight = height;\n",
        "    windowWidth = width;\n    windowHeight = height;\n"
        "    if (FCL_inputHook) {\n"
        "        FCL_inputHook(6, width, height, 0, 0, 0, 0);\n"
        "        return;\n"
        "    }\n",
    ),
    (
        "void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset) {\n",
        "void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset) {\n"
        "    if (FCL_inputHook) {\n"
        "        FCL_inputHook(5, 0, 0, 0, 0, xoffset, yoffset);\n"
        "        return;\n"
        "    }\n",
    ),
])

patch("Natives/JavaLauncher.m", [
    (
        '    NSLog(@"[JavaLauncher] Beginning JVM launch");\n',
        '    NSLog(@"[JavaLauncher] Beginning JVM launch");\n'
        "    BOOL usesModernLWJGL = NO;\n"
        "    if ([launchTarget isKindOfClass:NSDictionary.class]) {\n"
        '        for (NSDictionary *library in launchTarget[@"libraries"]) {\n'
        '            if ([library isKindOfClass:NSDictionary.class] && [library[@"name"] hasPrefix:@"org.lwjgl:lwjgl-sdl:"]) {\n'
        "                usesModernLWJGL = YES;\n"
        "                break;\n"
        "            }\n"
        "        }\n"
        "    }\n"
        '    NSLog(@"[JavaLauncher] Modern LWJGL runtime: %@", usesModernLWJGL ? @"YES" : @"NO");\n',
    ),
    (
        '    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;\n',
        "    if (usesModernLWJGL) {\n"
        '        margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%1$@/lwjgl_natives:%1$@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;\n'
        '        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.librarypath=%@/lwjgl_natives", NSBundle.mainBundle.bundlePath].UTF8String;\n'
        '        margv[++margc] = "-Dfcl.graphicsBackend=vulkan";\n'
        "    } else {\n"
        '        margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;\n'
        "    }\n",
    ),
    (
        '    NSString *classpath = [NSString stringWithFormat:@"%@/*", librariesPath];\n',
        '    NSString *classpath = [NSString stringWithFormat:@"%@/*", librariesPath];\n'
        "    if (usesModernLWJGL) {\n"
        "        NSMutableArray *classpathEntries = [NSMutableArray array];\n"
        "        for (NSString *file in [fm contentsOfDirectoryAtPath:librariesPath error:nil]) {\n"
        '            if ([file hasSuffix:@".jar"] && ![file isEqualToString:@"lwjgl.jar"]) {\n'
        "                [classpathEntries addObject:[librariesPath stringByAppendingPathComponent:file]];\n"
        "            }\n"
        "        }\n"
        '        [classpathEntries addObject:[NSString stringWithFormat:@"%@/libs_lwjgl/*", NSBundle.mainBundle.bundlePath]];\n'
        '        classpath = [classpathEntries componentsJoinedByString:@":"];\n'
        "    }\n",
    ),
])

patch("JavaApp/src/launcher/net/kdt/pojavlaunch/Tools.java", [
    (
        "        Method method = clazz.getMethod(\"main\", String[].class);\n",
        "        String graphicsBackend = System.getProperty(\"fcl.graphicsBackend\");\n"
        "        if (graphicsBackend != null) {\n"
        "            String[] extendedArgs = Arrays.copyOf(launchArgs, launchArgs.length + 2);\n"
        "            extendedArgs[launchArgs.length] = \"--graphicsBackend\";\n"
        "            extendedArgs[launchArgs.length + 1] = graphicsBackend;\n"
        "            launchArgs = extendedArgs;\n"
        "        }\n"
        "        Method method = clazz.getMethod(\"main\", String[].class);\n",
    ),
])

print("Engine patched")
