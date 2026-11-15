const one = <p>{value}</p>;
const call = <p>{compute(value)}</p>;
const spread = <p>{...items}</p>;
const empty = <p>{}</p>;
const comment = <p>{/* a note */}</p>;
const guarded = <p>{ready && <span>go</span>}</p>;
const mapped = <ul>{items.map((item: string) => <li key={item}>{item}</li>)}</ul>;
const typed = <p>{(value as string).length}</p>;
