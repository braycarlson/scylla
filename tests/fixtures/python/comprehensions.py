a = [x for x in y]
b = [x for x in y if x]
c = [x for x in y for z in x]
d = {x for x in y}
e = {x: y for x, y in z}
f = (x for x in y)
g = [x async for x in y]
h = [x for x in y if x if x > 1]
i = [(x, y) for x in a for y in b if x != y]
