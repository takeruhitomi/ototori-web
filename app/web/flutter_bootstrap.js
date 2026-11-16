{{flutter_js}}
{{flutter_build_config}}

// No Flutter service worker: coi-sw.js owns the scope (cross-origin
// isolation for multi-threaded recognition). CanvasKit is served locally
// (build with --no-web-resources-cdn) so it loads under require-corp.
_flutter.loader.load({
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById('ototori-boot')?.remove();
    await appRunner.runApp();
  },
});
