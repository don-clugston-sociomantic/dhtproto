/*******************************************************************************

    Fake DHT node Mirror request implementation.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module fakedht.neo.request.Mirror;

/*******************************************************************************

    Imports

*******************************************************************************/

import dhtproto.node.neo.request.Mirror;

import fakedht.neo.SharedResources;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;

import ocean.transition;

/*******************************************************************************

    The request handler for the table of handlers. When called, runs in a fiber
    that can be controlled via `connection`.

    Params:
        shared_resources = an opaque object containing resources owned by the
            node which are required by the request
        connection  = performs connection socket I/O and manages the fiber
        cmdver      = the version number of the Consume command as specified by
                      the client
        msg_payload = the payload of the first message of this request

*******************************************************************************/

public void handle ( Object shared_resources, RequestOnConn connection,
    Command.Version cmdver, Const!(void)[] msg_payload )
{
    auto resources = new SharedResources;

    switch ( cmdver )
    {
        case 0:
            scope rq = new MirrorImpl_v0(resources);
            rq.handle(connection, msg_payload);
            break;

        default:
            auto ed = connection.event_dispatcher;
            ed.send(
                ( ed.Payload payload )
                {
                    payload.addConstant(SupportedStatus.RequestVersionNotSupported);
                }
            );
            break;
    }
}

/*******************************************************************************

    Fake node implementation of the v0 Mirror request protocol.

*******************************************************************************/

import fakedht.Storage; // DhtListener

private scope class MirrorImpl_v0 : MirrorProtocol_v0, DhtListener
{
    import fakedht.Storage;
    import ocean.core.array.Mutation : copy;
    import ocean.text.convert.Hash : toHashT;

    /// Reference to channel being mirrored.
    private Channel channel;

    /// Name of channel being mirrored.
    private cstring channel_name;

    /// List of keys to visit during an iteration.
    private istring[] iterate_keys;

    /***************************************************************************

        Constructor.

        Params:
            shared_resources = DHT request resources getter

    ***************************************************************************/

    public this ( IRequestResources resources )
    {
        super(resources);
    }

    /***************************************************************************

        Performs any logic needed to subscribe to and start mirroring the
        channel of the given name.

        Params:
            channel_name = channel to mirror

        Returns:
            true if the channel may be used, false to abort the request

    ***************************************************************************/

    override protected bool prepareChannel ( cstring channel_name )
    {
        this.channel = global_storage.getCreate(channel_name);
        this.channel_name = channel_name.dup;
        return true;
    }

    /***************************************************************************

        Returns:
            the name of the channel being mirrored (for logging)

    ***************************************************************************/

    override protected cstring channelName ( )
    {
        return this.channel_name;
    }

    /***************************************************************************

        Registers this request to receive updates on the channel.

    ***************************************************************************/

    override protected void registerForUpdates ( )
    {
        assert(this.channel !is null);
        this.channel.register(this);
    }

    /***************************************************************************

        Unregisters this request from receiving updates on the channel.

    ***************************************************************************/

    override protected void unregisterForUpdates ( )
    {
        if (this.channel !is null)
            this.channel.unregister(this);
    }

    /***************************************************************************

        Gets the value of the record with the specified key, if it exists.

        Params:
            key = key of record to get from storage
            buf = buffer to write the value into

        Returns:
            record value or null, if the record does not exist

    ***************************************************************************/

    override protected void[] getRecordValue ( hash_t key, ref void[] buf )
    {
        auto storage_value = this.channel.get(key);
        if ( storage_value is null )
            return null;
        else
        {
            buf.copy(storage_value);
            return buf;
        }
    }

    /***************************************************************************

        Called to begin iterating over the channel being mirrored.

    ***************************************************************************/

    override protected void startIteration ( )
    in
    {
        assert(this.iterate_keys.length == 0, "Iteration already in progress");
    }
    body
    {
        this.iterate_keys = this.channel.getKeys();
    }

    /***************************************************************************

        Adds the next record in the iteration to the update queue, if one
        exists.

        Params:
            hash_key = output value to receive the next key to add to the queue

        Returns:
            true if hash_key was set or false if the iteration is finished

    ***************************************************************************/

    override protected bool iterateNext ( out hash_t hash_key )
    {
        if ( this.iterate_keys.length == 0 )
            return false;

        auto key = this.iterate_keys[$-1];
        this.iterate_keys.length = this.iterate_keys.length - 1;

        auto ok = toHashT(key, hash_key);
        assert(ok);

        return true;
    }

    /***************************************************************************

        DhtListener interface method. Called by Storage when records are
        modified or the channel is deleted.

        Params:
            code = trigger event code
            key  = new dht key

    ***************************************************************************/

    public void trigger ( Code code, cstring key )
    {
        with ( Code ) switch ( code )
        {
            case DataReady:
                hash_t hash_key;
                auto ok = toHashT(key, hash_key);
                assert(ok);

                this.updated(Update(UpdateType.Change, hash_key));
                break;

            case Deletion:
                hash_t hash_key;
                auto ok = toHashT(key, hash_key);
                assert(ok);

                this.updated(Update(UpdateType.Deletion, hash_key));
                break;

            case Finish:
                this.channelRemoved();
                break;

            default:
               break;
        }
    }
}