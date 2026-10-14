/* 支线管理后台：媒体灯箱弹窗。
   点击带 data-sq-media 的链接 → 页内弹窗查看图片 / 播放视频音频；
   Esc 关闭，←/→ 在组内切换，点击遮罩关闭。 */
(function () {
    'use strict';

    var MODAL_ID = 'sq-media-modal';

    function modalEl() {
        return document.getElementById(MODAL_ID);
    }

    function closeModal() {
        var el = modalEl();
        if (el) {
            el.remove();
        }
    }

    function collectGroup(anchor) {
        var groupName = anchor.getAttribute('data-sq-group');
        if (!groupName) {
            return [{ url: anchor.getAttribute('data-sq-media'), kind: anchor.getAttribute('data-sq-kind') }];
        }
        var nodes = document.querySelectorAll('a[data-sq-media][data-sq-group="' + groupName + '"]');
        var items = [];
        for (var i = 0; i < nodes.length; i++) {
            items.push({ url: nodes[i].getAttribute('data-sq-media'), kind: nodes[i].getAttribute('data-sq-kind') });
        }
        return items;
    }

    function renderItem(box, item) {
        box.innerHTML = '';
        var el;
        if (item.kind === 'video') {
            el = document.createElement('video');
            el.controls = true;
            el.autoplay = true;
            el.src = item.url;
        } else if (item.kind === 'audio') {
            el = document.createElement('audio');
            el.controls = true;
            el.autoplay = true;
            el.src = item.url;
        } else {
            el = document.createElement('img');
            el.alt = '媒体预览';
            el.src = item.url;
        }
        box.appendChild(el);
    }

    function openModal(items, index) {
        closeModal();
        var current = index;

        var overlay = document.createElement('div');
        overlay.id = MODAL_ID;
        overlay.className = 'sq-overlay';

        var inner = document.createElement('div');
        inner.className = 'sq-inner';

        var closeBtn = document.createElement('button');
        closeBtn.type = 'button';
        closeBtn.className = 'sq-close';
        closeBtn.setAttribute('aria-label', '关闭');
        closeBtn.textContent = '✕';
        closeBtn.addEventListener('click', function () { closeModal(); });
        inner.appendChild(closeBtn);

        var content = document.createElement('div');
        content.className = 'sq-content';
        inner.appendChild(content);

        var counter = null;

        function step(delta) {
            if (items.length < 2) {
                return;
            }
            current = (current + delta + items.length) % items.length;
            renderItem(content, items[current]);
            if (counter) {
                counter.textContent = (current + 1) + ' / ' + items.length;
            }
        }

        if (items.length > 1) {
            var prevBtn = document.createElement('button');
            prevBtn.type = 'button';
            prevBtn.className = 'sq-nav sq-prev';
            prevBtn.setAttribute('aria-label', '上一个');
            prevBtn.textContent = '‹';
            prevBtn.addEventListener('click', function () { step(-1); });
            inner.appendChild(prevBtn);

            var nextBtn = document.createElement('button');
            nextBtn.type = 'button';
            nextBtn.className = 'sq-nav sq-next';
            nextBtn.setAttribute('aria-label', '下一个');
            nextBtn.textContent = '›';
            nextBtn.addEventListener('click', function () { step(1); });
            inner.appendChild(nextBtn);

            counter = document.createElement('span');
            counter.className = 'sq-counter';
            counter.textContent = (current + 1) + ' / ' + items.length;
            inner.appendChild(counter);
        }

        renderItem(content, items[current]);

        overlay.addEventListener('click', function (event) {
            if (event.target === overlay) {
                closeModal();
            }
        });

        overlay.appendChild(inner);
        document.body.appendChild(overlay);
    }

    document.addEventListener('keydown', function (event) {
        if (!modalEl()) {
            return;
        }
        if (event.key === 'Escape') {
            closeModal();
        } else if (event.key === 'ArrowRight') {
            var next = modalEl().querySelector('.sq-next');
            if (next) {
                next.click();
            }
        } else if (event.key === 'ArrowLeft') {
            var prev = modalEl().querySelector('.sq-prev');
            if (prev) {
                prev.click();
            }
        }
    });

    document.addEventListener('click', function (event) {
        var anchor = event.target.closest ? event.target.closest('a[data-sq-media]') : null;
        if (!anchor) {
            return;
        }
        event.preventDefault();
        var items = collectGroup(anchor);
        var url = anchor.getAttribute('data-sq-media');
        var index = 0;
        for (var i = 0; i < items.length; i++) {
            if (items[i].url === url) {
                index = i;
                break;
            }
        }
        openModal(items, index);
    });
})();
