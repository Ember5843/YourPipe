(function () {
  var root = window;
  root.__yourpipeSabr = { status: 'helper-ready', error: '', botguardResponse: '' };

  root.yourpipeRunBotGuard = function (challenge) {
    var state = root.__yourpipeSabr;
    state.status = 'botguard-loading';
    try {
      new Function(challenge.interpreterJavascript)();
      var vm = root[challenge.globalName];
      if (!vm || !vm.a) throw new Error('BotGuard VM unavailable');
      var signalOutput = [];
      var functions = {};
      var interactionElement = document.getElementById('interaction') || document.body;
      state.syncSnapshotFunction = vm.a(challenge.program, function (asyncSnapshotFunction, shutdownFunction,
          passEventFunction, checkCameraFunction) {
        functions.asyncSnapshotFunction = asyncSnapshotFunction;
      }, true, interactionElement, function () {}, [[], []])[0];
      var polls = 0;
      var timer = setInterval(function () {
        if (functions.asyncSnapshotFunction) {
          clearInterval(timer);
          functions.asyncSnapshotFunction(function (response) {
            state.signalOutput = signalOutput;
            state.botguardResponse = response;
            state.status = 'botguard-ready';
          }, [undefined, undefined, signalOutput, undefined]);
        } else if (++polls > 10000) {
          clearInterval(timer);
          state.error = 'BotGuard async snapshot timeout';
          state.status = 'error';
        }
      }, 1);
    } catch (e) {
      state.error = String(e && e.stack ? e.stack : e);
      state.status = 'error';
    }
  };

  root.yourpipeCreateMinter = function (integrityToken) {
    var state = root.__yourpipeSabr;
    try {
      var getMinter = state.signalOutput && state.signalOutput[0];
      if (!getMinter) throw new Error('PO token minter factory unavailable');
      state.minter = getMinter(integrityToken);
      if (typeof state.minter !== 'function') throw new Error('PO token minter invalid');
      state.status = 'minter-ready';
      return 'minter-ready';
    } catch (e) {
      state.error = String(e && e.stack ? e.stack : e);
      state.status = 'error';
      return 'error:' + state.error;
    }
  };

  root.yourpipeMintPoToken = function (identifier) {
    var state = root.__yourpipeSabr;
    try {
      var bytes = new TextEncoder().encode(identifier);
      var token = state.minter(bytes);
      if (!(token instanceof Uint8Array)) throw new Error('PO token result invalid');
      return Array.prototype.join.call(token, ',');
    } catch (e) {
      state.error = String(e && e.stack ? e.stack : e);
      state.status = 'error';
      return '';
    }
  };
})();
