// Idioma do site (galeria e perfil compartilhado): só inglês.
(function () {
  function pick() { return "en"; }
  function apply() { document.documentElement.lang = "en"; }
  function wire() {}
  window.DDLang = { pick, apply, wire };
})();
