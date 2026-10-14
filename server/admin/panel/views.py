"""后台内的受保护媒体文件服务：登录的运营账号才能按 media_id 读取缩略图与内容文件。

- /media-thumb/<id>/：缩略图（列表页小图）
- /media-file/<id>/ ：内容文件（原图查看、视频/音频播放），支持 HTTP Range，可拖动进度条
"""
import re
from pathlib import Path

from django.conf import settings
from django.contrib.admin.views.decorators import staff_member_required
from django.http import FileResponse, Http404, HttpResponse

from .models import Media


@staff_member_required
def media_thumb(request, media_id):
    row = Media.objects.filter(id=media_id).values('thumbnail_name').first()
    if not row or not row['thumbnail_name']:
        raise Http404('thumbnail not found')
    path = Path(settings.SIDEQUEST_MEDIA_DIR) / media_id / row['thumbnail_name']
    if not path.is_file():
        raise Http404('thumbnail file missing')
    return FileResponse(open(path, 'rb'), content_type='image/jpeg')


@staff_member_required
def media_file(request, media_id):
    row = Media.objects.filter(id=media_id).values('content_name', 'mime_type').first()
    if not row or not row['content_name']:
        raise Http404('media content not found')
    path = Path(settings.SIDEQUEST_MEDIA_DIR) / media_id / row['content_name']
    if not path.is_file():
        raise Http404('media file missing')

    size = path.stat().st_size
    content_type = row['mime_type'] or 'application/octet-stream'
    match = re.match(r'bytes=(\d*)-(\d*)$', request.headers.get('Range', '').strip())

    if match and (match.group(1) or match.group(2)):
        if match.group(1):
            start = int(match.group(1))
            end = int(match.group(2)) if match.group(2) else size - 1
        else:  # 后缀范围 bytes=-N
            start = max(size - int(match.group(2)), 0)
            end = size - 1
        end = min(end, size - 1)
        if start > end or start >= size:
            response = HttpResponse(status=416)
            response['Content-Range'] = f'bytes */{size}'
            return response
        length = end - start + 1
        with open(path, 'rb') as handle:
            handle.seek(start)
            data = handle.read(length)
        response = HttpResponse(data, status=206, content_type=content_type)
        response['Content-Range'] = f'bytes {start}-{end}/{size}'
        response['Content-Length'] = str(length)
    else:
        response = FileResponse(open(path, 'rb'), content_type=content_type)

    response['Accept-Ranges'] = 'bytes'
    return response
