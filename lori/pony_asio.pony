use @pony_asio_event_create[AsioEventID](owner: AsioEventNotify, fd: U32,
  flags: U32, nsec: U64, noisy: Bool)
use @pony_asio_event_destroy[None](event: AsioEventID)
use @pony_asio_event_fd[U32](event: AsioEventID)
use @pony_asio_event_set_readable[None](event: AsioEventID, readable: Bool)
use @pony_asio_event_set_writeable[None](event: AsioEventID, writeable: Bool)
use @pony_asio_event_unsubscribe[None](event: AsioEventID)

primitive PonyASIO
  fun create_event(the_actor: AsioEventNotify, fd: U32): AsioEventID =>
    @pony_asio_event_create(the_actor, fd, AsioEvent.read_write(), 0, true)

  fun destroy(event: AsioEventID) =>
    @pony_asio_event_destroy(event)

  fun event_fd(event: AsioEventID): U32 =>
    @pony_asio_event_fd(event)

  fun set_readable(event: AsioEventID) =>
    @pony_asio_event_set_readable(event, true)

  fun set_unreadable(event: AsioEventID) =>
    @pony_asio_event_set_readable(event, false)

  fun set_writeable(event: AsioEventID) =>
    @pony_asio_event_set_writeable(event, true)

  fun set_unwriteable(event: AsioEventID) =>
    @pony_asio_event_set_writeable(event, false)

  fun unsubscribe(event: AsioEventID) =>
    @pony_asio_event_unsubscribe(event)
