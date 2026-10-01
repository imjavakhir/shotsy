#!/usr/bin/env python3
"""Regenerates Shotsy.xcodeproj/project.pbxproj and the shared scheme.

Source files live in Xcode synchronized folders (Shotsy/, Shared/, ShotsyTests/),
so adding a file never requires re-running this. Re-run only to change targets or build settings.
Owner-specific values (bundle ID, team) live in Config/Owner.xcconfig, not here.

Usage: python3 tools/generate_project.py   (from the repo root)
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = "\t"


def oid(n):
    return "5A10000000000000000%05X" % n


NAMES = dict(
    appRef=1, srcGroup=2, appFw=3, mainGroup=4, products=5, appTarget=6, appSources=7, appRes=8, project=9,
    lottieBF=0x10, lottieProd=0x11, lottiePkg=0x12, rcBF=0x13, rcProd=0x14, rcPkg=0x15,
    appCfgList=0x20, appDebug=0x21, appRelease=0x22, projCfgList=0x23, projDebug=0x24, projRelease=0x25,
    sharedGroup=0x40, widgetGroup=0x41, testsGroup=0x42, configGroup=0x43,
    xcconfigRef=0x44, appPlistRef=0x45, widgetPlistRef=0x46, appEntRef=0x47, widgetEntRef=0x48, storekitRef=0x49,
    widgetRef=0x50, widgetTarget=0x51, widgetSources=0x52, widgetFw=0x53, widgetRes=0x54,
    widgetCfgList=0x55, widgetDebug=0x56, widgetRelease=0x57,
    embedPhase=0x58, embedBF=0x59, widgetProxy=0x5A, widgetDep=0x5B,
    testsRef=0x60, testsTarget=0x61, testsSources=0x62, testsFw=0x63, testsRes=0x64,
    testsCfgList=0x65, testsDebug=0x66, testsRelease=0x67, testsProxy=0x68, testsDep=0x69,
)
I = {k: oid(v) for k, v in NAMES.items()}

REGIONS = ["en", "Base", "ru", "es", "pt-BR", "fr", "de", "it", "ja", "ko", "zh-Hans", "zh-Hant", "id", "vi"]

SWIFT = {
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1",
    "CURRENT_PROJECT_VERSION": "3",
    "MARKETING_VERSION": "1.0",
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "$(SHOTSY_TEAM_ID)",
}

APP = dict(SWIFT, **{
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Config/Shotsy-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Shotsy",
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.photography",
    # Only standard HTTPS (App Store, RevenueCat): exempt, so App Store Connect skips the export-compliance prompt.
    "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
    "INFOPLIST_KEY_NSPhotoLibraryUsageDescription":
        "Shotsy sorts, groups, and searches your photos on this iPhone. It changes your library only when you choose an action.",
    "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription":
        "Shotsy saves compressed video copies to your library when you ask it to.",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "$(SHOTSY_BUNDLE_ID)",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
})

TESTS = dict(SWIFT, **{
    "BUNDLE_LOADER": "$(TEST_HOST)",
    "GENERATE_INFOPLIST_FILE": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": "$(SHOTSY_BUNDLE_ID).tests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Shotsy.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Shotsy",
})

PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SDKROOT": "iphoneos",
    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
}
PROJ_DEBUG = dict(PROJECT_COMMON, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
PROJ_RELEASE = dict(PROJECT_COMMON, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
})


def q(value):
    safe = all(c.isalnum() or c in "_." for c in value)
    return value if value and safe else '"' + value.replace('"', '\\"') + '"'


def id_list(keys, depth):
    pad = T * depth
    return "".join(pad + I[k] + ",\n" for k in keys)


def build_settings(d):
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            items = "".join(T * 5 + q(x) + ",\n" for x in v)
            lines.append(T * 4 + k + " = (\n" + items + T * 4 + ");")
        else:
            lines.append(T * 4 + k + " = " + q(v) + ";")
    return "\n".join(lines)


def config(key, name, settings, base=None):
    base_line = (T * 3 + "baseConfigurationReference = " + I[base] + ";\n") if base else ""
    return (T * 2 + I[key] + " /* " + name + " */ = {\n"
            + T * 3 + "isa = XCBuildConfiguration;\n" + base_line
            + T * 3 + "buildSettings = {\n" + build_settings(settings) + "\n" + T * 3 + "};\n"
            + T * 3 + "name = " + name + ";\n" + T * 2 + "};\n")


def config_list(key, debug, release):
    return (T * 2 + I[key] + " = {\n" + T * 3 + "isa = XCConfigurationList;\n"
            + T * 3 + "buildConfigurations = (\n" + id_list([debug, release], 4) + T * 3 + ");\n"
            + T * 3 + "defaultConfigurationIsVisible = 0;\n" + T * 3 + "defaultConfigurationName = Release;\n"
            + T * 2 + "};\n")


def phase(key, isa, files=()):
    return (T * 2 + I[key] + " = {\n" + T * 3 + "isa = " + isa + ";\n"
            + T * 3 + "buildActionMask = 2147483647;\n"
            + T * 3 + "files = (\n" + id_list(files, 4) + T * 3 + ");\n"
            + T * 3 + "runOnlyForDeploymentPostprocessing = 0;\n" + T * 2 + "};\n")


def target(key, name, cfg, phases, groups, product, ptype, deps=(), pkgs=()):
    return (T * 2 + I[key] + " /* " + name + " */ = {\n"
            + T * 3 + "isa = PBXNativeTarget;\n"
            + T * 3 + "buildConfigurationList = " + I[cfg] + ";\n"
            + T * 3 + "buildPhases = (\n" + id_list(phases, 4) + T * 3 + ");\n"
            + T * 3 + "buildRules = (\n" + T * 3 + ");\n"
            + T * 3 + "dependencies = (\n" + id_list(deps, 4) + T * 3 + ");\n"
            + T * 3 + "fileSystemSynchronizedGroups = (\n" + id_list(groups, 4) + T * 3 + ");\n"
            + T * 3 + "name = " + name + ";\n"
            + T * 3 + "packageProductDependencies = (\n" + id_list(pkgs, 4) + T * 3 + ");\n"
            + T * 3 + "productName = " + name + ";\n"
            + T * 3 + "productReference = " + I[product] + ";\n"
            + T * 3 + 'productType = "' + ptype + '";\n' + T * 2 + "};\n")


def sync_group(key, path):
    return (T * 2 + I[key] + " /* " + path + " */ = {\n" + T * 3 + "isa = PBXFileSystemSynchronizedRootGroup;\n"
            + T * 3 + "path = " + path + ";\n" + T * 3 + 'sourceTree = "<group>";\n' + T * 2 + "};\n")


def file_ref(key, path, ftype):
    return (T * 2 + I[key] + " = {isa = PBXFileReference; lastKnownFileType = " + ftype
            + "; path = " + q(path) + '; sourceTree = "<group>"; };\n')


def product_ref(key, path, ftype):
    return (T * 2 + I[key] + " = {isa = PBXFileReference; explicitFileType = " + q(ftype)
            + "; includeInIndex = 0; path = " + q(path) + "; sourceTree = BUILT_PRODUCTS_DIR; };\n")


def proxy(key, remote, info):
    return (T * 2 + I[key] + " = {\n" + T * 3 + "isa = PBXContainerItemProxy;\n"
            + T * 3 + "containerPortal = " + I["project"] + ";\n" + T * 3 + "proxyType = 1;\n"
            + T * 3 + "remoteGlobalIDString = " + I[remote] + ";\n" + T * 3 + "remoteInfo = " + info + ";\n"
            + T * 2 + "};\n")


def dependency(key, tgt, prx):
    return (T * 2 + I[key] + " = {\n" + T * 3 + "isa = PBXTargetDependency;\n"
            + T * 3 + "target = " + I[tgt] + ";\n" + T * 3 + "targetProxy = " + I[prx] + ";\n" + T * 2 + "};\n")


def group(key, children, name=None, path=None):
    extra = (T * 3 + "name = " + name + ";\n" if name else "") + (T * 3 + "path = " + path + ";\n" if path else "")
    return (T * 2 + I[key] + " = {\n" + T * 3 + "isa = PBXGroup;\n"
            + T * 3 + "children = (\n" + id_list(children, 4) + T * 3 + ");\n"
            + extra + T * 3 + 'sourceTree = "<group>";\n' + T * 2 + "};\n")


def section(name, body):
    return "/* Begin " + name + " section */\n" + body + "/* End " + name + " section */\n\n"


objects = "".join([
    section("PBXBuildFile",
            T * 2 + I["lottieBF"] + " = {isa = PBXBuildFile; productRef = " + I["lottieProd"] + "; };\n"
            + T * 2 + I["rcBF"] + " = {isa = PBXBuildFile; productRef = " + I["rcProd"] + "; };\n"),
    section("PBXContainerItemProxy",
            proxy("testsProxy", "appTarget", "Shotsy")),
    section("PBXFileReference",
            product_ref("appRef", "Shotsy.app", "wrapper.application")
            + product_ref("testsRef", "ShotsyTests.xctest", "wrapper.cfbundle")
            + file_ref("xcconfigRef", "Owner.xcconfig", "text.xcconfig")
            + file_ref("appPlistRef", "Shotsy-Info.plist", "text.plist.xml")
            + file_ref("storekitRef", "Shotsy.storekit", "text")),
    section("PBXFileSystemSynchronizedRootGroup",
            sync_group("srcGroup", "Shotsy") + sync_group("sharedGroup", "Shared")
            + sync_group("testsGroup", "ShotsyTests")),
    section("PBXFrameworksBuildPhase",
            phase("appFw", "PBXFrameworksBuildPhase", ["lottieBF", "rcBF"])
            + phase("testsFw", "PBXFrameworksBuildPhase")),
    section("PBXGroup",
            group("mainGroup", ["srcGroup", "sharedGroup", "testsGroup", "configGroup", "products"])
            + group("configGroup", ["xcconfigRef", "appPlistRef", "storekitRef"], path="Config")
            + group("products", ["appRef", "testsRef"], name="Products")),
    section("PBXNativeTarget",
            target("appTarget", "Shotsy", "appCfgList", ["appSources", "appFw", "appRes"],
                   ["srcGroup", "sharedGroup"], "appRef", "com.apple.product-type.application",
                   pkgs=["lottieProd", "rcProd"])
            + target("testsTarget", "ShotsyTests", "testsCfgList", ["testsSources", "testsFw", "testsRes"],
                     ["testsGroup"], "testsRef", "com.apple.product-type.bundle.unit-test", deps=["testsDep"])),
    section("PBXProject",
            T * 2 + I["project"] + " /* Project object */ = {\n" + T * 3 + "isa = PBXProject;\n"
            + T * 3 + "attributes = {\n" + T * 4 + "BuildIndependentTargetsInParallel = 1;\n"
            + T * 4 + "LastSwiftUpdateCheck = 2600;\n" + T * 4 + "LastUpgradeCheck = 2600;\n"
            + T * 4 + "TargetAttributes = {\n"
            + T * 5 + I["appTarget"] + " = {\n" + T * 6 + "CreatedOnToolsVersion = 26.0;\n" + T * 5 + "};\n"
            + T * 5 + I["testsTarget"] + " = {\n" + T * 6 + "CreatedOnToolsVersion = 26.0;\n"
            + T * 6 + "TestTargetID = " + I["appTarget"] + ";\n" + T * 5 + "};\n"
            + T * 4 + "};\n" + T * 3 + "};\n"
            + T * 3 + "buildConfigurationList = " + I["projCfgList"] + ";\n"
            + T * 3 + "developmentRegion = en;\n" + T * 3 + "hasScannedForEncodings = 0;\n"
            + T * 3 + "knownRegions = (\n" + "".join(T * 4 + q(r) + ",\n" for r in REGIONS) + T * 3 + ");\n"
            + T * 3 + "mainGroup = " + I["mainGroup"] + ";\n" + T * 3 + "minimizedProjectReferenceProxies = 1;\n"
            + T * 3 + "packageReferences = (\n" + id_list(["lottiePkg", "rcPkg"], 4) + T * 3 + ");\n"
            + T * 3 + "preferredProjectObjectVersion = 77;\n"
            + T * 3 + "productRefGroup = " + I["products"] + ";\n"
            + T * 3 + 'projectDirPath = "";\n' + T * 3 + 'projectRoot = "";\n'
            + T * 3 + "targets = (\n" + id_list(["appTarget", "testsTarget"], 4) + T * 3 + ");\n"
            + T * 2 + "};\n"),
    section("PBXResourcesBuildPhase",
            phase("appRes", "PBXResourcesBuildPhase")
            + phase("testsRes", "PBXResourcesBuildPhase")),
    section("PBXSourcesBuildPhase",
            phase("appSources", "PBXSourcesBuildPhase")
            + phase("testsSources", "PBXSourcesBuildPhase")),
    section("PBXTargetDependency",
            dependency("testsDep", "appTarget", "testsProxy")),
    section("XCBuildConfiguration",
            config("appDebug", "Debug", APP) + config("appRelease", "Release", APP)
            + config("testsDebug", "Debug", TESTS) + config("testsRelease", "Release", TESTS)
            + config("projDebug", "Debug", PROJ_DEBUG, base="xcconfigRef")
            + config("projRelease", "Release", PROJ_RELEASE, base="xcconfigRef")),
    section("XCConfigurationList",
            config_list("appCfgList", "appDebug", "appRelease")
            + config_list("testsCfgList", "testsDebug", "testsRelease")
            + config_list("projCfgList", "projDebug", "projRelease")),
    section("XCRemoteSwiftPackageReference",
            T * 2 + I["lottiePkg"] + " = {\n" + T * 3 + "isa = XCRemoteSwiftPackageReference;\n"
            + T * 3 + 'repositoryURL = "https://github.com/airbnb/lottie-spm";\n'
            + T * 3 + "requirement = {\n" + T * 4 + "kind = upToNextMajorVersion;\n"
            + T * 4 + "minimumVersion = 4.5.0;\n" + T * 3 + "};\n" + T * 2 + "};\n"
            + T * 2 + I["rcPkg"] + " = {\n" + T * 3 + "isa = XCRemoteSwiftPackageReference;\n"
            + T * 3 + 'repositoryURL = "https://github.com/RevenueCat/purchases-ios-spm";\n'
            + T * 3 + "requirement = {\n" + T * 4 + "kind = upToNextMajorVersion;\n"
            + T * 4 + "minimumVersion = 5.0.0;\n" + T * 3 + "};\n" + T * 2 + "};\n"),
    section("XCSwiftPackageProductDependency",
            T * 2 + I["lottieProd"] + " = {\n" + T * 3 + "isa = XCSwiftPackageProductDependency;\n"
            + T * 3 + "package = " + I["lottiePkg"] + ";\n" + T * 3 + "productName = Lottie;\n" + T * 2 + "};\n"
            + T * 2 + I["rcProd"] + " = {\n" + T * 3 + "isa = XCSwiftPackageProductDependency;\n"
            + T * 3 + "package = " + I["rcPkg"] + ";\n" + T * 3 + "productName = RevenueCat;\n" + T * 2 + "};\n"),
])

pbx = ("// !$*UTF8*$!\n{\n" + T + "archiveVersion = 1;\n" + T + "classes = {\n" + T + "};\n"
       + T + "objectVersion = 77;\n" + T + "objects = {\n\n" + objects + T + "};\n"
       + T + "rootObject = " + I["project"] + " /* Project object */;\n}\n")

with open(os.path.join(ROOT, "Shotsy.xcodeproj/project.pbxproj"), "w") as f:
    f.write(pbx)


def ref(target_key, product, name):
    return ('<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "' + I[target_key]
            + '" BuildableName = "' + product + '" BlueprintName = "' + name
            + '" ReferencedContainer = "container:Shotsy.xcodeproj"></BuildableReference>')


APP_REF = ref("appTarget", "Shotsy.app", "Shotsy")
scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            APP_REF
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO" parallelizable = "NO">
            TEST_REF
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         APP_REF
      </BuildableProductRunnable>
      <StoreKitConfigurationFileReference identifier = "../../Config/Shotsy.storekit">
      </StoreKitConfigurationFileReference>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         APP_REF
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""".replace("APP_REF", APP_REF).replace("TEST_REF", ref("testsTarget", "ShotsyTests.xctest", "ShotsyTests"))

os.makedirs(os.path.join(ROOT, "Shotsy.xcodeproj/xcshareddata/xcschemes"), exist_ok=True)
with open(os.path.join(ROOT, "Shotsy.xcodeproj/xcshareddata/xcschemes/Shotsy.xcscheme"), "w") as f:
    f.write(scheme)
print("Generated project.pbxproj and Shotsy.xcscheme")
