from django.db import models


class LocationField(models.Model):
    name = models.CharField(max_length=255)
