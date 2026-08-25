def run(first, second=1, *rest, keyword=2, **extra):
    return first, second, rest, keyword, extra


lam = lambda left, right=1: left + right
