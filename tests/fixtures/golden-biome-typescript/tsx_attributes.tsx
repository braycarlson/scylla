const bare = <input disabled />;
const quoted = <input type="text" placeholder="name" />;
const braced = <input value={held} onChange={update} />;
const spread = <input {...rest} />;
const hyphen = <div data-role="row" aria-label="grid" />;
const namespaced = <svg xlink:href="#id" />;
const element = <Panel header={<Title />} />;
