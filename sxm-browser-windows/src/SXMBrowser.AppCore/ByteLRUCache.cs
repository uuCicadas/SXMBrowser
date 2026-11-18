using System;
using System.Collections.Generic;

namespace SXMBrowser.AppCore;

/// <summary>
/// Byte-cost-bounded LRU cache using an O(1) dictionary + doubly-linked recency list.
/// </summary>
public sealed class ByteLRUCache<TKey, TValue> where TKey : notnull
{
    private sealed class Node
    {
        public readonly TKey Key;
        public TValue Value;
        public int Cost;
        public Node? Previous;
        public Node? Next;

        public Node(TKey key, TValue value, int cost)
        {
            Key = key;
            Value = value;
            Cost = cost;
        }
    }

    private readonly Dictionary<TKey, Node> _entries = [];
    private Node? _leastRecent;
    private Node? _mostRecent;

    public int ByteLimit { get; }
    public int TotalCost { get; private set; }
    public int Count => _entries.Count;
    public bool IsEmpty => _entries.Count == 0;

    public ByteLRUCache(int byteLimit)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(byteLimit);
        ByteLimit = byteLimit;
    }

    public IReadOnlyList<TKey> KeysFromLeastToMostRecent
    {
        get
        {
            var keys = new List<TKey>(_entries.Count);
            Node? current = _leastRecent;
            while (current is not null)
            {
                keys.Add(current.Key);
                current = current.Next;
            }
            return keys;
        }
    }

    public bool Contains(TKey key) => _entries.ContainsKey(key);

    public int? Cost(TKey key) => _entries.TryGetValue(key, out Node? node) ? node.Cost : null;

    public bool TryGetValue(TKey key, out TValue value)
    {
        if (_entries.TryGetValue(key, out Node? node))
        {
            MakeMostRecent(node);
            value = node.Value;
            return true;
        }
        value = default!;
        return false;
    }

    public bool Insert(TValue value, TKey key, int cost)
    {
        if (cost < 0) return false;

        if (_entries.TryGetValue(key, out Node? existing))
        {
            RemoveNode(existing);
        }

        if (cost > ByteLimit)
        {
            return false;
        }

        while (TotalCost > ByteLimit - cost && _leastRecent is not null)
        {
            RemoveNode(_leastRecent);
        }

        var node = new Node(key, value, cost);
        _entries[key] = node;
        AppendAsMostRecent(node);
        TotalCost += cost;
        return true;
    }

    public bool TryRemoveValue(TKey key, out TValue value)
    {
        if (_entries.TryGetValue(key, out Node? node))
        {
            RemoveNode(node);
            value = node.Value;
            return true;
        }
        value = default!;
        return false;
    }

    public void RemoveAll()
    {
        _entries.Clear();
        _leastRecent = null;
        _mostRecent = null;
        TotalCost = 0;
    }

    private void MakeMostRecent(Node node)
    {
        if (ReferenceEquals(_mostRecent, node)) return;
        Unlink(node);
        AppendAsMostRecent(node);
    }

    private void AppendAsMostRecent(Node node)
    {
        node.Previous = _mostRecent;
        node.Next = null;
        if (_mostRecent is not null)
        {
            _mostRecent.Next = node;
        }
        else
        {
            _leastRecent = node;
        }
        _mostRecent = node;
    }

    private void RemoveNode(Node node)
    {
        _entries.Remove(node.Key);
        TotalCost -= node.Cost;
        Unlink(node);
    }

    private void Unlink(Node node)
    {
        if (node.Previous is not null)
        {
            node.Previous.Next = node.Next;
        }
        else
        {
            _leastRecent = node.Next;
        }

        if (node.Next is not null)
        {
            node.Next.Previous = node.Previous;
        }
        else
        {
            _mostRecent = node.Previous;
        }

        node.Previous = null;
        node.Next = null;
    }
}
