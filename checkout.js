// Tela de checkout da loja: mostra só a seção do gateway escolhido e adiciona produtos
(function () {
  'use strict';
  var form = document.getElementById('form-checkout');
  if (!form) return;
  function atualizar() {
    var sel = form.querySelector('input[name=gateway]:checked');
    var g = sel ? sel.value : '';
    form.querySelectorAll('.gw-sec').forEach(function (s) { s.hidden = s.dataset.gw !== g; });
    form.querySelectorAll('.so-link').forEach(function (i) { i.hidden = g !== 'link'; });
  }
  form.querySelectorAll('input[name=gateway]').forEach(function (r) { r.addEventListener('change', atualizar); });
  document.getElementById('mais-prod').addEventListener('click', function () {
    var box = document.getElementById('prods');
    var n = box.children.length;
    if (n >= 10) { alert('Máximo de 10 produtos.'); return; }
    var modelo = box.children[0].cloneNode(true);
    modelo.querySelectorAll('input').forEach(function (i) {
      i.value = '';
      i.name = i.name.replace(/_\d+$/, '_' + n);
      i.setAttribute('aria-label', i.getAttribute('aria-label').replace(/\d+$/, n + 1));
      if (i.name.indexOf('p_nome_') === 0) i.placeholder = 'Nome do produto ' + (n + 1);
    });
    box.appendChild(modelo);
    atualizar();
  });
  atualizar();
})();
