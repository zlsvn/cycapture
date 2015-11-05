# -*- coding: utf-8 -*-

cdef void sig_handler(int signum) nogil:
    cdef thread_pcap_node* current = BlockingSniffer.get_pcap_for_thread(pthread_self())
    if current != NULL:
        current.asked_to_stop = 1
        pcap_breakloop(current.handle)


# noinspection PyAttributeOutsideInit,PyGlobalUndefined
cdef class BlockingSniffer(Sniffer):
    """
    Blocking sniffer
    """
    active_sniffers = {}

    def __cinit__(self, interface=None, filename=None, int read_timeout=5000, int buffer_size=0, int snapshot_length=2000,
                  promisc_mode=False, monitor_mode=False, direction=PCAP_D_INOUT):
        self.parent_thread = NULL

    def __init__(self, interface=None, filename=None, int read_timeout=5000, int buffer_size=0, int snapshot_length=2000,
                 promisc_mode=False, monitor_mode=False, direction=PCAP_D_INOUT):
        """
        __init__(interface=None, filename=None, int read_timeout=5000, int buffer_size=0, int snapshot_length=2000, promisc_mode=False, monitor_mode=False, direction=PCAP_D_INOUT)

        Parameters
        ----------
        interface
        filename
        read_timeout
        buffer_size
        snapshot_length
        promisc_mode
        monitor_mode
        direction
        """
        Sniffer.__init__(self, interface, filename, read_timeout, buffer_size, snapshot_length, promisc_mode, monitor_mode, direction)

    def __dealloc__(self):
        self.close()

    @classmethod
    def stop_all(cls):
        [s.ask_stop() for s in cls.active_sniffers.values()]


    cpdef ask_stop(self):
        if self.parent_thread != NULL:
            if pthread_kill(self.parent_thread[0], SIGUSR1) != 0:
                raise RuntimeError("BlockingSniffer.stop (sending SIGUSR1) failed")

    cdef void _set_signal_mask(self) nogil:
        cdef sigset_t s
        sigfillset(&s)
        pthread_sigmask(SIG_BLOCK, &s, NULL)
        sigemptyset(&s)
        sigaddset(&s, SIGUSR1)
        pthread_sigmask(SIG_UNBLOCK, &s, NULL)



    def sniff_and_export(self, fname_or_file_object, int max_p=-1):
        w = PacketWriter(self.datalink[0], fname_or_file_object)

        def _callback(sec, usec, caplen, length, mview):
            w.write(mview, sec, usec)

        self.sniff_callback(_callback, max_p=max_p)

    def iterator(self, f=None, int max_p=-1, int cache_size=10000):
        return SniffingIterator(self, f, max_p, cache_size)


    cpdef sniff_callback(self, f, int set_signal_mask=1, int max_p=-1):
        global sig_handler
        cdef int counted = 0

        cdef char* error_msg = NULL
        cdef char* error_msg_source = NULL
        cdef thread_pcap_node* node
        # keep a reference to the callback... just in case...
        self.python_callback = f
        self.python_callback_ptr = <unsigned char *> (<void*> self.python_callback)

        if set_signal_mask:
            self._set_signal_mask()

        self.total = 0
        self.max_p = max_p
        with self._activate_if_needed():
            node = self.register()
            try:
                # the nogil here is important: without it, the other python threads may not be able to run
                with nogil:
                    while node.asked_to_stop == 0:
                        counted = pcap_dispatch(self._handle, 0, _do_python_callback, self.python_callback_ptr)
                        if counted == -2:
                            # pcap_breakloop was called
                            node.asked_to_stop = 1
                            break
                        elif counted < 0:
                            error_msg_source = pcap_geterr(self._handle)
                            error_msg = <char *> malloc(strlen(error_msg_source) + 1)
                            if error_msg != NULL:
                                strcpy(error_msg, error_msg_source)
                            node.asked_to_stop = 1
                            break
                        else:
                            self.total += counted

                        if 0 < self.max_p <= self.total:
                            node.asked_to_stop = 1
                            break

            finally:
                self.unregister()

        if error_msg != NULL:
            msg = bytes(error_msg)
            free(error_msg)
            raise PcapExceptionFactory(counted, msg, default=SniffingError)

    cpdef sniff_and_store(self, container, f=None, int set_signal_mask=1, int max_p=-1):
        global _store_c_callback, sig_handler
        cdef int counted = 0
        cdef sighandler_t h = <sighandler_t> sig_handler
        cdef sighandler_t old_sigint
        cdef bytes error_message = b''
        cdef thread_pcap_node* node

        cdef dispatch_user_param usr
        cdef list_head head
        cdef list_head* cursor
        cdef list_head* nextnext
        cdef packet_node* pkt_node

        usr.fun = _store_c_callback

        cdef store_fun store
        if f is None:
            store = BlockingSniffer.store_packet_node_in_seq
        else:
            store = BlockingSniffer.store_packet_node_in_seq_with_f


        if set_signal_mask:
            self._set_signal_mask()

        self.total = 0
        self.max_p = max_p

        with self._activate_if_needed():
            node = self.register()

            try:
                while node.asked_to_stop == 0:
                    with nogil:
                        INIT_LIST_HEAD(&head)
                        usr.param = <void*>&head
                        counted = pcap_dispatch(self._handle, 0, _do_c_callback, <unsigned char*> &usr)

                    cursor = head.next
                    nextnext = cursor.next
                    while cursor != &head:
                        pkt_node = <packet_node*>( <char *>cursor - <unsigned long> (&(<packet_node*>0).link) )
                        store(pkt_node, container, f)           # python code... need the GIL
                        free(pkt_node.buf)
                        list_del(&pkt_node.link)
                        free(pkt_node)
                        cursor = nextnext
                        nextnext = cursor.next

                    if counted == -2:
                        # pcap_breakloop was called
                        node.asked_to_stop = 1
                        break
                    elif counted < 0:
                        error_message = <bytes> (pcap_geterr(self._handle))
                        node.asked_to_stop = 1
                        break
                    else:
                        self.total += counted

                    if 0 < self.max_p <= self.total:
                        node.asked_to_stop = 1
                        break

            finally:
                self.unregister()

        if error_message:
            raise PcapExceptionFactory(counted, bytes(error_message), default=SniffingError)


    cdef thread_pcap_node* register(self) except NULL:
        if self._handle is NULL:
            raise RuntimeError("register: no valid pcap handle")
        if self in BlockingSniffer.active_sniffers.values():
            raise RuntimeError("register: this BlockingSniffer is already actively listening")
        if BlockingSniffer.thread_has_pcap(pthread_self()) == 1:
            raise RuntimeError("register: only one sniffing action per thread is allowed")
        cdef thread_pcap_node* node = BlockingSniffer.register_pcap_for_thread(self._handle)    # can raise exc too
        self.parent_thread = copy_pthread_self()
        self.active_sniffers[pthread_self_as_bytes()] = self
        cdef sighandler_t h = <sighandler_t> sig_handler
        self.old_sigint = libc_signal(SIGUSR1, h)
        siginterrupt(SIGUSR1, 1)
        return node

    cdef unregister(self):
        libc_signal(SIGUSR1, self.old_sigint)
        siginterrupt(SIGUSR1, 1)
        BlockingSniffer.unregister_pcap_for_thread()        # can raise exc
        cdef bytes ident = pthread_self_as_bytes()
        if ident in self.active_sniffers:
            del self.active_sniffers[ident]
        if self.parent_thread != NULL:
            free(self.parent_thread)
            self.parent_thread = NULL


    @staticmethod
    cdef thread_pcap_node* register_pcap_for_thread(pcap_t* handle) except NULL:
        global lock, thread_pcap_global_list

        cdef thread_pcap_node* node
        cdef pthread_t thread = pthread_self()
        if BlockingSniffer.thread_has_pcap(thread) == 1:
            raise RuntimeError("register_pcap_for_thread: this thread already has a pcap handle")

        if pthread_mutex_lock(lock) != 0:
            raise RuntimeError("register_pcap_for_thread: locking failed!!!")
        try:
            node = <thread_pcap_node*> malloc(sizeof(thread_pcap_node))
            if node is NULL:
                raise RuntimeError('register_pcap_for_thread: malloc failed!!!')
            node.thread = thread
            node.handle = handle
            node.asked_to_stop = 0
            list_add_tail(&node.link, &thread_pcap_global_list)
        finally:
            pthread_mutex_unlock(lock)
        return node


    @staticmethod
    cdef unregister_pcap_for_thread():
        global lock, thread_pcap_global_list
        cdef list_head* cursor
        cdef list_head* nextnext
        cdef thread_pcap_node* node
        cdef pthread_t thread = pthread_self()
        if BlockingSniffer.thread_has_pcap(thread) == 0:
            return "Warning: unregister_pcap_for_thread: current thread doesnt have a pcap handle"

        if pthread_mutex_lock(lock) != 0:
            raise RuntimeError("unregister_pcap_for_thread: locking failed!!!")

        try:
            cursor = thread_pcap_global_list.next
            nextnext = cursor.next
            while cursor != &thread_pcap_global_list:
                node = <thread_pcap_node*>( <char *>cursor - <unsigned long> (&(<thread_pcap_node*>0).link) )
                if pthread_equal(node.thread, thread):
                    list_del(&node.link)
                    free(node)
                    break
                cursor = nextnext
                nextnext = cursor.next
        finally:
            pthread_mutex_unlock(lock)


    @staticmethod
    cdef thread_pcap_node* get_pcap_for_thread(pthread_t thread) nogil:
        global thread_pcap_global_list
        cdef list_head* cursor = thread_pcap_global_list.next
        cdef thread_pcap_node* node
        while cursor != &thread_pcap_global_list:
            node = <thread_pcap_node*>( <char *>cursor - <unsigned long> (&(<thread_pcap_node*>0).link) )
            if pthread_equal(node.thread, thread):
                return node
            cursor = cursor.next
        return NULL
