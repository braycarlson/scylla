from django import forms

from catalog.models import Product


class ProductForm(forms.ModelForm):
    class Meta:
        fields = ('description', 'is_active', 'name', 'price', 'sku')
        model = Product
