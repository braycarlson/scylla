from django.db import models


class Product(models.Model):
    blob = models.BinaryField(default=b'')
    category = models.ForeignKey('Category', on_delete=models.CASCADE)
    name = models.CharField(max_length=64)
    price = models.DecimalField(decimal_places=2, max_digits=10)
    secret = models.CharField(max_length=64)


class Category(models.Model):
    label = models.CharField(max_length=64)
