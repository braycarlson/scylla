const plain = `text`;
const empty = ``;
const substituted = `before ${value} after`;
const many = `${one}${two}`;
const nested = `outer ${`inner ${deep}`} tail`;
const expressive = `${one + two}`;
const objectish = `${{ key: 1 }.key}`;
const tagged = tag`text ${value}`;
const membered = tag.method`text`;
const multiline = `line
break`;
