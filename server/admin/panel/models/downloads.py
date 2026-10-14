"""下载统计（数据由主服务写 <SIDEQUEST_DOWNLOADS>，后台只读聚合展示，不建表）。

注意：这里统计的只是下载链接的公开访问（网页落地页与下载请求），
与支线 App 内部没有任何关系——App 不采集、不上报任何行为数据。
"""
from django.db import models


class DownloadEvent(models.Model):
    at = models.CharField(max_length=64, blank=True, default='')

    class Meta:
        managed = False
        db_table = 'download_events_stub'
        verbose_name = '下载统计'
        verbose_name_plural = '下载统计'
