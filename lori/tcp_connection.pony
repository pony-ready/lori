use "collections"

interface tag TCPConnectionActor
  fun ref self(): TCPConnection


  fun ref on_closed()
    """
    Called when the connection is closed
    """

  fun ref on_connected()
    """
    Called when a connection is opened
    """

  fun ref on_received(data: Array[U8] iso)
    """
    Called each time data is received on this connection
    """

  fun ref on_throttled() =>
    """
    Called when we start experiencing backpressure
    """

    None

  fun ref on_unthrottled() =>
    """
    Called when backpressure is released
    """

    None

  be dispose() =>
    """
    Close connection
    """
    close()

  be open() =>
    // TODO: this is kind of misnamed. coming from accept in listener.
    // would like to make this a `fun` be then, how does a listener trigger it?
    let event = PonyASIO.create_event(this, self().fd)
    self().event = event
    self().open()
    // should set readable state
    PonyASIO.set_writeable(self().event)
    on_connected()

  fun ref close() =>
    if self().is_open() then
      self().close()
      PonyTCP.shutdown(self().fd)
      PonyASIO.unsubscribe(self().event)
      self().fd = -1
    end

  fun ref connect(host: String, port: String, from: String) =>
    """
    Called to open a new outgoing connection
    """
    let connect_count = PonyTCP.connect(this, host, port, from)
/*    if connect_count > 0 then
      // TODO: call out for connecting?
      return
    else
      // TODO: handle failure
      return
    end
*/

  fun ref send(data: ByteSeq) =>
    if self().is_open() then
      if self().is_writeable() then
        if not self().has_pending_writes() then
          try
            let len = PonyTCP.send(self().event, data)?
            if (len < data.size()) then
              // unable to write all data
              self().add_pending_data(data, len)
              _apply_backpressure()
            end
          else
            // TODO: is there any way to get here if the connection is open?
            return
          end
        else
          self().add_pending_data(data, 0)
          _send_pending_writes()
        end
      else
        self().add_pending_data(data, 0)
      end
    end

  be _event_notify(event: AsioEventID, flags: U32, arg: U32) =>
    if event isnt self().event then
      if AsioEvent.writeable(flags) then
        // TODO: this assumes the connection succeed. That might not be true.
        // more logic needs to go here
        let fd = PonyASIO.event_fd(event)
        self().fd = fd
        self().event = event
        self().open()
        on_connected()
        _read()
      end
    end

    if event is self().event then
      if AsioEvent.readable(flags) then
        // should set that we are readable
        _read()
      end

      if AsioEvent.writeable(flags) then
        self().writeable()
        _send_pending_writes()
      end

      if AsioEvent.disposable(flags) then
        PonyASIO.destroy(event)
        self().event = AsioEvent.none()
      end
    end

  fun ref _read() =>
    try
      if self().is_open() then
        let buffer = recover Array[U8].>undefined(64) end
        let bytes_read = PonyTCP.receive(self().event, buffer.cpointer(), buffer.size())?
        if (bytes_read == 0) then
          PonyASIO.set_unreadable(self().event)
          // would block. try again later
    // TCPConnection handles with:
          //@pony_asio_event_set_readable[None](self().event, false)
          // _readable = false
          // @pony_asio_event_resubscribe_read(_event)
    return
        end

        buffer.truncate(bytes_read)
        on_received(consume buffer)
        _read_again()
      end
    else
      // Socket shutdown from other side
      close()
    end

  be _read_again() =>
    """
    Resume reading
    """
    _read()

  fun ref _send_pending_writes() =>
    while self().is_writeable() and (self().has_pending_writes()) do
      try
        let node = self().pending_head()?
        (let data, let offset) = node()?

        let len = PonyTCP.send(self().event, data, offset)?

        if (len + offset) < data.size() then
          // not all data was sent
          node()? = (data, offset + len)
          _apply_backpressure()
        else
          self().pending_shift()?
        end
      else
        // error sending. appears our connection has been shutdown.
        // TODO: handle close here
        None
      end
    end

    if self().has_pending_writes() then
      // all pending data was sent
      _release_backpressure()
    end

  fun ref _apply_backpressure() =>
    if not self().is_throttled() then
      self().throttled()
      on_throttled()
    end

  fun ref _release_backpressure() =>
    if self().is_throttled() then
      self().unthrottled()
      on_unthrottled()
    end

class TCPConnection
  var fd: U32
  var event: AsioEventID = AsioEvent.none()
  var _state: U32 = 0
  let _pending: List[(ByteSeq, USize)] = _pending.create()

  new client() =>
    fd = -1

  new server(fd': U32) =>
    fd = fd'

  fun is_closed(): Bool =>
    not is_open()

  fun is_open(): Bool =>
    BitSet.is_set(_state, 0)

  fun ref open() =>
    _state = BitSet.set(_state, 0)
    writeable()

  fun ref close() =>
    _state = BitSet.unset(_state, 0)
    unwriteable()

  fun is_writeable(): Bool =>
    BitSet.is_set(_state, 1)

  fun ref writeable() =>
    _state = BitSet.set(_state, 1)

  fun ref unwriteable() =>
    _state = BitSet.unset(_state, 1)

  fun is_throttled(): Bool =>
    BitSet.is_set(_state, 2)

  fun ref throttled() =>
    _state = BitSet.set(_state, 2)
    // throttled means we are also unwriteable
    // being unthrottled doesn't however mean we are writable
    unwriteable()
    PonyASIO.set_unwriteable(event)

  fun ref unthrottled() =>
    _state = BitSet.unset(_state, 2)

  fun has_pending_writes(): Bool =>
    _pending.size() != 0

  fun ref add_pending_data(data: ByteSeq, offset: USize) =>
    _pending.push((data, offset))

  fun ref pending_head(): ListNode[(ByteSeq, USize)] ? =>
    _pending.head()?

  fun ref pending_shift(): (ByteSeq, USize) ? =>
    _pending.shift()?

/* maybe move _send_pending_writes here

  pros:
    - encapsulate pending data usage
    - would move most backpressure logic into here where it
      probably belongs

  cons:
    - TPCConnection needs to know about enclosing actor or it
      needs to have return type for change in backpressure
    - With PonyTCP called from in here, we'd need to make both this class
      and the actor interface generic and over the same thing that
      implements PonyTCP once we start allowing that to be specialized.

      However, we are already doing that by using PonyASIO in here, although,
      I have no plans at this time to allow that to be specialized, except,
      it could be useful for testing to make it so.


  fun ref send_pending_writes() =>
    while is_writeable() and has_pending_writes() do
      try
        let node = _pending.head()?
        (let data, let offset) = node()?

        let len = PonyTCP.send(self().event, data, offset)?

        if (len + offset) < data.size() then
          // not all data was sent
          node()? = (data, offset + len)
          _apply_backpressure()
        else
          _pending.shift()?
        end
      else
        // error sending. appears our connection has been shutdown.
        // TODO: handle close here
        None
      end
    end

    if pending_writes() then
      // all pending data was sent
      _release_backpressure()
    end
*/
