// The app's entry. The engine, AppMain included, is in the MetalRenderer library (Sources/MetalRenderer), the demo
// scenes in the Game library (Sources/Game); the tests import both: one build of each serves all.
import Game
import MetalRenderer

GameScenes.register()
AppMain.run()
