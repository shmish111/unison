package org.unisonweb.util

import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicBoolean
import scala.collection.immutable.LongMap

/**
 * Encoder/decoder for graphs of type `G` with references of type `R`.
 *
 * Each `G` has some number of children, which are also of type `G`,
 * accessed via `foreach`.
 *
 * Some `G` are _references_, of type `R`, which can be set via `setReference`
 * and created via `makeReference`.
 *
 * Each `G` also has some binary data, called the _byte prefix_, accessed
 * via `writeBytePrefix`.
 *
 * The interface requires that the byte prefix plus the children be sufficient
 * to reconstitute the `G`.
 */
trait GraphCodec[G,R] {
  import GraphCodec._

  def writeBytePrefix(graph: G, sink: Sink): Unit

  /** `R` must be embeddable in `G`. */
  def inject(r: R): G

  def foreach(graph: G)(f: G => Unit): Unit

  def children(graph: G): Sequence[G] = {
    var cs = Sequence.empty[G]
    foreach(graph) { g => cs = cs :+ g }
    cs
  }

  def isReference(graph: G): Boolean
  def dereference(graph: R): G

  def foldLeft[B](graph: G)(b0: B)(f: (B,G) => B): B = {
    var b = b0
    foreach(graph)(g => b = f(b,g))
    b
  }

  /**
   * Encode a `G` to the given `Sink`.
   * `includeRefMetadata` controls whether the `bytePrefix`
   * of each `g: G` which passes `isReference(g)` is written
   * to the output as well.
   */
  def encodeTo(buf: Sink): G => Unit = {
    val seen = new IdentityHashMap[G,Long]()
    def go(g: G): Unit = {
      if (isReference(g)) {
        val r = g.asInstanceOf[R]
        val pos = seen.get(g)
        if (pos eq null) {
          seen.put(g, buf.position)
          buf.putByte(RefMarker.toByte)
          writeBytePrefix(inject(r), buf)
          go(dereference(r))
        }
        else {
          buf.putByte(RefSeenMarker.toByte)
          buf.putLong(pos)
        }
      }
      else {
        val pos = seen.get(g)
        if (pos eq null) {
          seen.put(g, buf.position)
          buf.putByte(NestedStartMarker.toByte) // indicates a Nested follows
          writeBytePrefix(g, buf)
          foreach(g)(go)
          buf.putByte(NestedEndMarker.toByte)
        }
        else {
          buf.putByte(SeenMarker.toByte)
          buf.putLong(pos)
        }
      }
    }
    go(_)
  }

  /** Produce a decoder for `G` that reads from the given `Source`.
    * Implementations may wish to use `GraphCodec.decoder` to implement
    * this function.
    */
  def stageDecoder(src: Source): () => G

  /** Convenience function to write out a sequence of byte chunks for a `G`. */
  def encode(g: G): Sequence[Array[Byte]] = {
    var buf = Sequence.empty[Array[Byte]]
    val bb = java.nio.ByteBuffer.allocate(1024)
    val encoder = encodeTo(Sink.fromByteBuffer(bb, arr => buf = buf :+ arr))
    encoder(g)
    if (bb.position() != 0) {
      // there are leftover bytes buffered in `bb`, flush them
      val rem = new Array[Byte](bb.position)
      bb.position(0)
      bb.get(rem)
      buf :+ rem
    }
    else buf
  }

  /** Convenience function to read a `G` from a sequence of chunks. */
  def decode(chunks: Sequence[Array[Byte]]): G =
    stageDecoder(Source.fromChunks(chunks))()
}

object GraphCodec {
  final val NestedStartMarker = -1
  final val NestedEndMarker = -2
  final val SeenMarker = -3
  final val RefMarker = -4
  final val RefSeenMarker = -5

  trait Decoder[G,R] {
    def decode(readChild: () => Option[G]): G
    def decodeReference(position: Long, readReferent: () => G): R
  }

  def decoder[G,R](src: Source, inject: R => G)(d: Decoder[G,R]): () => G = {
    case object NestedEnd extends Throwable { override def fillInStackTrace = this }
    var decoded = LongMap.empty[G]

    // todo: why can't this switch on Byte?
    def read1: G = { val pos = src.position; (src.getByte.toInt: @annotation.switch) match {
      case NestedStartMarker =>
        var reachedEnd = new AtomicBoolean(false)
        var invalidated = new AtomicBoolean(false)
        val next = readChild(invalidated, reachedEnd)
        val g = d.decode(next)
        drain(next)
        decoded = decoded.updated(pos, g)
        g
      case NestedEndMarker => throw NestedEnd
      case SeenMarker => decoded(src.getLong)
      case RefMarker =>
        lazy val referent = read1
        val r = d.decodeReference(src.position, () => referent)
        referent // force the referent to be decoded
        val gr = inject(r)
        decoded = decoded.updated(pos, gr)
        gr // we return the reference, not the thing inside the reference
      case RefSeenMarker => decoded(src.getLong)
      case b => sys.error("unknown byte in GraphCodec decoding stream: " + b)
    }}

    @annotation.tailrec
    def drain(f: () => Option[G]): Unit = f() match {
      case None => ()
      case Some(_) => drain(f)
    }

    def readChild(invalidate: AtomicBoolean, reachedEnd: AtomicBoolean): () => Option[G] = () => {
      invalidate.set(true)
      if (!reachedEnd.get) {
        try Some(read1)
        catch { case NestedEnd => reachedEnd.set(true); None }
      }
      else None
    }

    () => read1
  }
}

