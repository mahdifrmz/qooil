## Binary Protocol

* Message = TypeId + Header + Body
* endianness = little endian

### TypeId

detemines message header type.

### Header

* fixed size (per TypeId)
* includes length & layout of body