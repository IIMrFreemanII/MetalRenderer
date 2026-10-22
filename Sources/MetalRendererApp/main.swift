// The app's entry. AppMain (the window, the panels, the editors) is in the Editors library (Sources/Editors), on the
// engine (Sources/MetalRenderer, on Sources/EngineCore); the demo scenes are in the Game library (Sources/Game). The
// tests import them all: one build of each serves both.
import Editors
import Game

GameScenes.register()
AppMain.run()
