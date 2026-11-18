# Vita3KiOS: app bundle settings and resources. Included from vita3k/CMakeLists.txt when IOS is set.
#
# iOS bundles are flat: the executable, Info.plist and resources all live at the root of Vita3K.app.
# Signing is not done here; CI fake-signs with ldid using ios/Vita3K.entitlements, and the sideloading
# tool (AltStore, SideStore, ...) re-signs with the user's certificate.

set(VITA3K_IOS_BUNDLE_ID "org.vita3k.ios" CACHE STRING "Bundle identifier of the iOS app")
set(VITA3K_IOS_VERSION "1.0.0" CACHE STRING "Marketing version of the iOS app")

set_target_properties(vita3k PROPERTIES
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist.in"
	MACOSX_BUNDLE_GUI_IDENTIFIER "${VITA3K_IOS_BUNDLE_ID}"
	MACOSX_BUNDLE_BUNDLE_NAME "Hinoki"
	MACOSX_BUNDLE_SHORT_VERSION_STRING "${VITA3K_IOS_VERSION}"
	MACOSX_BUNDLE_BUNDLE_VERSION "${VITA3K_IOS_VERSION}"
	XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/ios/Vita3K.entitlements"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)

add_custom_command(
	TARGET vita3k
	POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/../data" "$<TARGET_FILE_DIR:vita3k>/data"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/shaders-builtin" "$<TARGET_FILE_DIR:vita3k>/shaders-builtin"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/icons" "$<TARGET_FILE_DIR:vita3k>/icons"
	# The menus in the player's language: es.lproj, fr.lproj, ... at the root of the bundle
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/ios/localization" "$<TARGET_FILE_DIR:vita3k>"
	COMMENT "Copying Vita3K resources into the iOS app bundle")

# RAM helpers: V3KRamHelper.appex, an app extension that runs as separate processes (each with its own
# memory limit) and lends memory to Vita3K. Embedded in Vita3K.app/PlugIns. See ios/ramhelper/protocol.h.
add_executable(V3KRamHelper MACOSX_BUNDLE
	ios/ramhelper/extension.mm
	ios/ramhelper/protocol.h
)
set_source_files_properties(ios/ramhelper/extension.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_link_libraries(V3KRamHelper PRIVATE "-framework Foundation")
set_target_properties(V3KRamHelper PROPERTIES
	BUNDLE_EXTENSION appex
	XCODE_PRODUCT_TYPE com.apple.product-type.app-extension
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/ramhelper/Info.plist.in"
	MACOSX_BUNDLE_GUI_IDENTIFIER "${VITA3K_IOS_BUNDLE_ID}.RamHelper"
	MACOSX_BUNDLE_SHORT_VERSION_STRING "${VITA3K_IOS_VERSION}"
	MACOSX_BUNDLE_BUNDLE_VERSION "${VITA3K_IOS_VERSION}"
	XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${VITA3K_IOS_BUNDLE_ID}.RamHelper"
	XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "17.4"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
	XCODE_ATTRIBUTE_SKIP_INSTALL YES
	XCODE_ATTRIBUTE_APPLICATION_EXTENSION_API_ONLY YES
)

# Built-in JIT: StikJIT (StikDebug's JIT engine as a library, by the StikDebug team, MPL-2.0; it bundles
# jkcoxson's idevice, MIT) is compiled into the helper extension, which attaches a debugger to Hinoki
# (an app can't debug itself). Fetched at a fixed commit; without it the helper answers that this build
# has no built-in JIT. See ios/ramhelper/builtin_jit.mm.
set(STIKJIT_COMMIT a9ccad90c7a8cb547f77ff338890e6633a65ac43)
set(STIKJIT_DIR "${CMAKE_BINARY_DIR}/stikjit")
if(NOT EXISTS "${STIKJIT_DIR}/Sources/StikJIT.swift")
	file(REMOVE_RECURSE "${STIKJIT_DIR}")
	file(MAKE_DIRECTORY "${STIKJIT_DIR}")
	execute_process(COMMAND git init --quiet WORKING_DIRECTORY "${STIKJIT_DIR}")
	execute_process(COMMAND git fetch --quiet --depth 1 https://github.com/StikDebug/StikJIT.git ${STIKJIT_COMMIT}
		WORKING_DIRECTORY "${STIKJIT_DIR}" RESULT_VARIABLE STIKJIT_FETCH)
	if(STIKJIT_FETCH EQUAL 0)
		execute_process(COMMAND git checkout --quiet FETCH_HEAD WORKING_DIRECTORY "${STIKJIT_DIR}")
	endif()
endif()
if(EXISTS "${STIKJIT_DIR}/Sources/StikJIT.swift")
	message(STATUS "Built-in JIT: StikJIT ${STIKJIT_COMMIT}")
	file(GLOB STIKJIT_SWIFT "${STIKJIT_DIR}/Sources/*.swift")
	set(STIKJIT_SCRIPTS "${STIKJIT_DIR}/Scripts/universal.js" "${STIKJIT_DIR}/Scripts/legacy.js")
	target_sources(V3KRamHelper PRIVATE ${STIKJIT_SWIFT} ios/ramhelper/builtin_jit_helper.swift ${STIKJIT_SCRIPTS})
	target_compile_definitions(V3KRamHelper PRIVATE V3K_HELPER_HAS_STIKJIT=1)
	target_link_libraries(V3KRamHelper PRIVATE
		"-L${STIKJIT_DIR}/idevice" "-Wl,-hidden-lidevice_ffi"
		"-framework JavaScriptCore" "-framework Network" "-framework Security" "-framework CFNetwork"
		"-framework SystemConfiguration" "-framework IOKit")
	set_target_properties(V3KRamHelper PROPERTIES
		Swift_LANGUAGE_VERSION 5
		XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
		XCODE_ATTRIBUTE_SWIFT_INCLUDE_PATHS "${STIKJIT_DIR}/idevice ${STIKJIT_DIR}/iokit"
		XCODE_ATTRIBUTE_HEADER_SEARCH_PATHS "${STIKJIT_DIR}/idevice ${STIKJIT_DIR}/iokit"
		XCODE_ATTRIBUTE_LIBRARY_SEARCH_PATHS "${STIKJIT_DIR}/idevice"
		XCODE_ATTRIBUTE_DEAD_CODE_STRIPPING YES
		RESOURCE "${STIKJIT_SCRIPTS}")
else()
	message(WARNING "Built-in JIT: could not fetch StikJIT, the helper is built without it")
endif()

add_dependencies(vita3k V3KRamHelper)
set_target_properties(vita3k PROPERTIES
	XCODE_EMBED_APP_EXTENSIONS V3KRamHelper
	XCODE_EMBED_APP_EXTENSIONS_REMOVE_HEADERS_ON_COPY YES
)
