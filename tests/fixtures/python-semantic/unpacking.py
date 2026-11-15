def with_targets(manager):
    with manager as (first, second):
        pass
    with manager as [third, fourth]:
        pass
    with manager as ((fifth, sixth)):
        pass


def chained(holder):
    holder.value = (p1, p2) = [1, 2]
    data = o1, o2 = [1, 2]
    q = (r1, r2) = 1, 2
    (s1, s2) = (t1, t2) = 1, 2
    u1, u2 = v = [1, 2]
    w = {1, 2}
