const plain = <p>hello</p>;
const spaced = <p> </p>;
const around = <p> pad </p>;
const broken = <p>first line second line</p>;
const between = (
    <p>
        {one} middle {two}
    </p>
);
const entity = <p>&amp;</p>;
const entities = <p>a &amp; b &#65; c &#x41; d</p>;
const wrapped = (
    <div>
        <span>one</span>
        <span>two</span>
    </div>
);
