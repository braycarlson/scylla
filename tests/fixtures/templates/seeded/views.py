from django_glue import Glue


def args_view(request):
    # lintcheck-expect: glue/registration-args
    Glue.queryset(request=request, unique_name='rows', target=a)

    return render(request, 'seeded/args.html')


def duplicate_view(request):
    Glue.model(request=request, unique_name='item', target=a, fields=['id'])

    # lintcheck-expect: glue/duplicate-unique-name
    Glue.model(request=request, unique_name='item', target=b, fields=['id'])

    return render(request, 'seeded/duplicate.html')


def dead_view(request):
    # lintcheck-expect: glue/dead-registration
    Glue.json(request=request, unique_name='never_read', target=1)

    return render(request, 'seeded/dead.html')


def access_view(request):
    Glue.model(request=request, unique_name='product', target=a, fields=['id'])

    return render(request, 'seeded/access.html')


def naming_view(request):
    Glue.queryset(request=request, unique_name='products', target=a, fields=['id'])

    return render(request, 'seeded/naming.html')


def no_init_view(request):
    Glue.model(request=request, unique_name='thing', target=a, fields=['id'])

    return render(request, 'seeded/no_init.html')


def fields_view(request):
    # lintcheck-expect: glue/unknown-field
    Glue.model(request=request, unique_name='typo', target=Product(), fields=['name', 'nope'])

    return render(request, 'seeded/fields.html')


def binary_view(request):
    # lintcheck-expect: glue/unknown-field
    Glue.model(request=request, unique_name='blobby', target=Product(), fields=['name', 'blob'])

    return render(request, 'seeded/binary.html')


def filtered_view(request):
    # lintcheck-expect: glue/sensitive-field
    Glue.model(request=request, unique_name='card', target=Product(), fields=['name', 'secret'])

    return render(request, 'seeded/filtered.html')


def target_view(request):
    # lintcheck-expect: glue/unresolvable-target
    Glue.template(request=request, unique_name='ghost', target='seeded/nowhere.html')

    # lintcheck-expect: glue/unresolvable-target
    Glue.function(request=request, unique_name='caller', target='seeded.services.absent')

    return render(request, 'seeded/target.html')


def broad_view(request):
    # lintcheck-expect: glue/over-broad-access
    Glue.model(request=request, unique_name='readonly', target=Product(), fields=['name'], access=Glue.Access.DELETE)

    return render(request, 'seeded/broad.html')


def order_view(request):
    Glue.model(request=request, unique_name='early', target=Product(), fields=['name'])

    return render(request, 'seeded/order.html')
