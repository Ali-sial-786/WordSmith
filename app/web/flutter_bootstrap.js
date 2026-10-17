{{flutter_js}}
{{flutter_build_config}}

// Starts the game inside #flutter-host (index.html), which sits inside the
// iPhone's safe area, and tells the loading screen how far it has got.
// No service worker: updates come from the no-cache headers in web/_headers.
(function () {
  'use strict';

  var shell = window.wordsmithShell || {
    stage: function () {},
    started: function () {},
    fail: function (e) { console.error(e); },
  };

  // Flutter's old caching service worker, if a browser ever got one here,
  // would keep serving stale builds. Only that one: leave any others alone.
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.getRegistrations().then(function (registrations) {
      registrations.forEach(function (r) {
        var sw = r.active || r.waiting || r.installing;
        if (sw && /flutter_service_worker\.js/.test(sw.scriptURL)) r.unregister();
      });
    }).catch(function () {});
  }

  // Engine settings. A custom onEntrypointLoaded has to pass them to
  // initializeEngine itself.
  var config = {
    hostElement: document.getElementById('flutter-host'),
  };

  try {
    var loading = _flutter.loader.load({
      config: config,
      onEntrypointLoaded: async function (engineInitializer) {
        try {
          shell.stage('Heating the iron');
          var appRunner = await engineInitializer.initializeEngine(config);
          shell.stage('Striking the anvil');
          await appRunner.runApp();
          shell.started();
        } catch (e) {
          shell.fail(e);
        }
      },
    });
    if (loading && typeof loading.catch === 'function') loading.catch(shell.fail);
  } catch (e) {
    shell.fail(e);
  }

  // main.dart.js failing to download never calls onEntrypointLoaded.
  window.addEventListener('error', function (e) {
    var src = e && e.target && e.target.src;
    if (src && /main\.dart\.js|canvaskit/.test(src)) shell.fail(new Error('Could not load ' + src));
  }, true);
})();
