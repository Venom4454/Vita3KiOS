add_library(
	app
	STATIC
	include/app/functions.h
	include/app/session_controller.h
	include/app/discord.h
	include/app/state.h
	src/app_init.cpp
	src/app.cpp
	src/apps_list.cpp
	src/discord.cpp
	src/session_controller.cpp
	src/user.cpp
)

target_include_directories(app PUBLIC include)

# The game fixes list built in for when it can't be downloaded: the same file as the one online
# (dist/game-fixes.txt), read when CMake runs, so the two can't drift apart
set(HINOKI_GAME_FIXES "${CMAKE_CURRENT_SOURCE_DIR}/../../dist/game-fixes.txt")
if(EXISTS "${HINOKI_GAME_FIXES}")
	file(READ "${HINOKI_GAME_FIXES}" HINOKI_GAME_FIXES_TEXT)
	set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${HINOKI_GAME_FIXES}")
	file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/generated/app/default_game_fixes.inc" "R\"HINOKIFIXES(${HINOKI_GAME_FIXES_TEXT})HINOKIFIXES\"\n")
	target_include_directories(app PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
	target_compile_definitions(app PRIVATE HINOKI_DEFAULT_FIXES_FILE)
endif()
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_link_libraries(app PUBLIC emuenv mem cpu)
if(USE_DISCORD_RICH_PRESENCE)
  target_link_libraries(app PUBLIC discord-rpc)
endif()
target_link_libraries(app PRIVATE audio camera config ctrl dialog display gdbstub gxm ime io mem modules motion net ngs np patch regmgr renderer touch SDL3::SDL3 pugixml::pugixml compat packages http)
if(WIN32)
	target_link_libraries(app PRIVATE dwmapi)
endif()

if (LINUX)
    find_package(X11 REQUIRED)
    target_link_libraries(app PRIVATE ${X11_LIBRARIES})
endif()
