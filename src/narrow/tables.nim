import std/macros

import nimarrow_glib

import ./arrays

## An ArrowTable is an ordered collection of named arrays (columns).
## Each column name and type is described by its ArrowField,
## and an ArrowSchema describes all of the columns in a table.
##
## To construct a table, we use an ArrowTableBuilder which is
## constructed with the intended schema. Each column's data must
## then be added to the builder in the order specified by the
## schema. Creating a table does not copy any of the column
## data, it will share the internal buffers of the arrays used
## to construct it.

type
  ArrowFieldObj = object
    glibField: GArrowFieldPtr
  ArrowField* = ref ArrowFieldObj

  ArrowSchemaObj = object
    glibSchema: GArrowSchemaPtr
  ArrowSchema* = ref ArrowSchemaObj

  ArrowTableObj = object
    schema: ArrowSchema
    glibTable: GArrowTablePtr
  ArrowTable* = ref ArrowTableObj

  ArrowTableBuilder* = ref object
    valid: bool
    schema: ArrowSchema
    glibArrays: seq[GArrowArrayPtr]

proc `=destroy`*(x: var ArrowFieldObj) =
  if x.glibField != nil:
    gObjectUnref(x.glibField)

proc `=destroy`*(x: var ArrowSchemaObj) =
  if x.glibSchema != nil:
    gObjectUnref(x.glibSchema)

proc `=destroy`*(x: var ArrowTableObj) =
  if x.glibTable != nil:
    gObjectUnref(x.glibTable)

proc newArrowField[T](name: string, typeTag: TypeTag[T]): ArrowField =
  let glibDataType = getDataType(typeTag)
  defer: gObjectUnref(glibDataType)
  ArrowField(glibField: fieldNew(name, glibDataType))

proc newArrowField*(name: string, T: typedesc): ArrowField =
  ## Create a new field of type T named `name`.
  newArrowFIeld[T](name, TypeTag[T]())

proc glibPtr*(field: ArrowField): GArrowFieldPtr =
  ## Access the underlying glib field pointer.
  field.glibField

proc newArrowSchema*(fields: openArray[ArrowField]): ArrowSchema =
  ## Construct a new schema from a sequence of fields.
  var fieldList: GListPtr

  for field in fields:
    fieldList = glistAppend(fieldList, field.glibField)

  defer: glistFree(fieldList)
  ArrowSchema(glibSchema: schemaNew(fieldList))

proc newArrowSchema*(glibSchema: GArrowSchemaPtr): ArrowSchema =
  ## Construct an ArrowSchema from a glib schema pointer. NOTE: this takes
  ## ownership of the pointer and does not increase the refcount.
  doAssert glibSchema != nil
  ArrowSchema(glibSchema: glibSchema)

proc glibPtr*(schema: ArrowSchema): GArrowSchemaPtr =
  ## Access the underlying glib schema pointer.
  schema.glibSchema

proc newArrowTable*(schema: ArrowSchema, glibTable: GArrowTablePtr): ArrowTable =
  ## Construct an ArrowTable from schema and glib table pointer. NOTE: this takes
  ## ownership of the pointer and does not increase the refcount.
  doAssert glibTable != nil
  ArrowTable(schema: schema, glibTable: glibTable)

proc glibPtr*(table: ArrowTable): GArrowTablePtr =
  ## Access the underlying glib table pointer.
  table.glibTable

proc len*(table: ArrowTable): uint64 =
  ## Get the length (number of rows) of the table.
  tableGetNRows(table.glibTable)

proc `$`*(table: ArrowTable): string =
  ## String representation of the table's schema and full contents.
  var error: GErrorPtr
  result = $tableToString(table.glibTable, error)
  if error != nil:
    defer: gErrorFree(error)
    raise newException(ValueError, $error.message)

proc `$`*(schema: ArrowSchema): string =
  ## String representation of the table's schema and full contents.
  var error: GErrorPtr
  result = $schemaToString(schema.glibSchema, error)
  if error != nil:
    defer: gErrorFree(error)
    raise newException(ValueError, $error.message)

proc `==`*(table, other: ArrowTable): bool =
  tableEqual(table.glibPtr, other.glibPtr)

proc schema*(table: ArrowTable): ArrowSchema =
  table.schema

proc col*(table: ArrowTable, T: typedesc, i: int): ArrowChunkedArray[T] =
  let glibChunkedArray = tableGetColumnData(table.glibTable, i)
  doAssert glibChunkedArray != nil

  newArrowChunkedArray[T](glibChunkedArray)

proc col*(table: ArrowTable, T: typedesc, name: string): ArrowChunkedArray[T] =
  let index = schemaGetFieldIndex(table.schema.glibSchema, name)
  if index == -1:
    raise newException(CatchableError, "invalid column " & name)

  table.col(T, index)

proc newArrowTableBuilder*(schema: ArrowSchema): ArrowTableBuilder =
  ## Construct a new table builder for a given schema. Each column
  ## specified in the schema must be added using `add` in order.
  ArrowTableBuilder(schema: schema, valid: true)

proc add*[T](b: ArrowTableBuilder, arr: ArrowArray[T]) =
  ## Add the next column to the builder, must be of the correct type
  ## specified in the schema.
  doAssert b.valid

  let i = b.glibArrays.len
  let expectedField = schemaGetField(b.schema.glibSchema, uint(i))
  let expectedDtype = fieldGetDataType(expectedField)
  doAssert dataTypeEqual(expectedDtype, getDataType(TypeTag[T]()))

  b.glibArrays.add arr.glibPtr

proc build*(b: ArrowTableBuilder): ArrowTable =
  ## Build the table, invalidating this builder.
  doAssert uint(b.glibArrays.len) == schemaNFields(b.schema.glibPtr)
  b.valid = false

  let glibArraysPtr = cast[ptr UncheckedArray[GArrowArrayPtr]](addr b.glibArrays[0])
  let nArrays = uint64(b.glibArrays.len)
  var error: GErrorPtr
  let glibTable = tableNewArrays(b.schema.glibSchema, glibArraysPtr, nArrays, error)
  if error != nil:
    defer: gErrorFree(error)
    raise newException(ValueError, $error.message)

  newArrowTable(b.schema, glibTable)

type
  TypedBuilder*[T] = ref object of RootObj

  TypeRegistered* {.explain.} = concept b, type T
    add(TypedBuilder[T], b)
    schema(TypedBuilder[T]) is ArrowSchema
    build(TypedBuilder[T]) is ArrowTable
    newTypedBuilder(T) is TypedBuilder[T]
    for x in iter(ArrowTable, T):
      x is T

template newArrowTable*(T: typedesc, ts: openArray[T]): ArrowTable =
  let typedBuilder = newTypedBuilder(T)
  typedBuilder.add(ts)
  typedBuilder.build

proc add*[T](typedBuilder: TypedBuilder[T], ts: openArray[T]) =
  for t in ts:
    typedBuilder.add t

macro registerTypedTable*(typ: typedesc): untyped =
  ## Macro which registers a type to be used in the "Typed" API.
  result = newStmtList()

  let
    typDef = getImpl(typ)
    recList = if typDef[2].kind == nnkRefTy: typDef[2][0][2]
              else: typDef[2][2]
    builderTypName = ident($typ & "TableBuilder")
    newBuilderProcName = ident("newTypedBuilder")
    addProcName = ident("add")
    buildProcName = ident("build")
    schemaProcName = ident("schema")
    iterProcName = ident("iter")
    paramBuilder = ident("builder")
    paramValue = ident("x")
    paramTable = ident("tbl")
    fields = ident("fields")
    tblBuilder = ident("tblBuilder")
    castBuilder = ident("castBuilder")
    tag = ident("tag")
    typTag = quote do:
      TypeTag[`typ`]
    typedBuilder = quote do:
      TypedBuilder[`typ`]
    builderRecList = newNimNode(nnkRecList)

  builderRecList.add newIdentDefs(ident("schema"), ident("ArrowSchema"))

  for i, identDefs in recList:
    let
      fieldName = identDefs[0][1]
      fieldType = identDefs[1]
      arrayBuilderType = quote do:
        ArrowArrayBuilder[`fieldType`]

    builderRecList.add newIdentDefs(fieldName, arrayBuilderType)

  let
    inheritTypedBuilder = newTree(nnkOfInherit, typedBuilder)
    builderObj = newTree(nnkObjectTy, newEmptyNode(), inheritTypedBuilder, builderRecList)
    refBuilderObj = newTree(nnkRefTy, builderObj)
    builderTypDef = newTree(
      nnkTypeDef, builderTypName, newEmptyNode(), refBuilderObj)
    typSection = newTree(nnkTypeSection, builderTypDef)

  let newbuilderProcBody = newStmtList()

  newBuilderProcBody.add quote do:
    var `fields` = newSeq[ArrowField]()

  for i, identDefs in recList:
    let
      fieldName = newStrLitNode($identDefs[0][1])
      fieldType = identDefs[1]

    newbuilderProcBody.add quote do:
      `fields`.add newArrowField(`fieldName`, TypeTag[`fieldType`]())

  newbuilderProcBody.add quote do:
    let `castBuilder` = new(`builderTypName`)
    `castBuilder`.schema = newArrowSchema(`fields`)

  for i, identDefs in recList:
    let
      fieldName = identDefs[0][1]
      fieldType = identDefs[1]
      newArrayBuilderCall = quote do:
        newArrowArrayBuilder[`fieldType`]()

      resultDotBuilder = newDotExpr(`castBuilder`, fieldName)
      assignBuilder = newAssignment(resultDotBuilder, newArrayBuilderCall)

    newbuilderProcBody.add assignBuilder

  newBuilderProcBody.add quote do:
    cast[`typedBuilder`](`castBuilder`)

  let newbuilderProc = newProc(
    name = newbuilderProcName,
    params = [typedBuilder, nnkIdentDefs.newTree(tag, typTag, newEmptyNode())],
    body = newbuilderProcBody
  )

  let addBody = newStmtList()

  addBody.add quote do:
    let `castBuilder` = cast[`builderTypName`](`paramBuilder`)

  for i, identDefs in recList:
    let
      fieldName = identDefs[0][1]
      fieldBuilder = newDotExpr(castBuilder, fieldName)
      fieldAccess = newDotExpr(paramValue, fieldName)

    addBody.add quote do:
      `fieldBuilder`.add(`fieldAccess`)

  let addProc = newProc(
    name = postfix(addProcName, "*"),
    params = [
      newEmptyNode(),
      nnkIdentDefs.newTree(paramBuilder, typedBuilder, newEmptyNode()),
      nnkIdentDefs.newTree(paramValue, typ, newEmptyNode())
    ],
    body = addBody
  )

  let buildBody = newStmtList()
  buildBody.add quote do:
    let `castBuilder` = cast[`builderTypName`](`paramBuilder`)
    let `tblBuilder` = newArrowTableBuilder(`castBuilder`.schema)

  for i, identDefs in recList:
    let
      fieldName = identDefs[0][1]
      fieldBuilder = newDotExpr(castBuilder, fieldName)

    buildBody.add quote do:
      `tblBuilder`.add(`fieldBuilder`.build)

  buildBody.add quote do:
    `tblBuilder`.build

  let buildProc = newProc(
    name = postfix(buildProcName, "*"),
    params = [
      ident("ArrowTable"),
      nnkIdentDefs.newTree(paramBuilder, typedBuilder, newEmptyNode())
    ],
    body = buildBody
  )

  let schemaBody = quote do:
    let `castBuilder` = cast[`builderTypName`](`paramBuilder`)
    `castBuilder`.schema

  let schemaProc = newProc(
    name = postfix(schemaProcName, "*"),
    params = [
      ident("ArrowSchema"),
      nnkIdentDefs.newTree(paramBuilder, typedBuilder, newEmptyNode())
    ],
    body = schemaBody
  )

  let
    size = ident("size")
    iterBody = newStmtList()
    iterIndex = ident("i")
    objConstr = newNimNode(nnkObjConstr)

  iterBody.add quote do:
    let `size` = `paramTable`.len

  objConstr.add ident($typ)

  for i, identDefs in recList:
    let
      fieldName = identDefs[0][1]
      fieldType = ident($(identDefs[1]))
      arrName = ident($fieldName & "Arr")

    iterBody.add quote do:
      let `arrName` = @(`paramTable`.col(`fieldType`, `i`))

    objConstr.add newColonExpr(
      fieldName,
      nnkBracketExpr.newTree(arrName, iterIndex))

  iterBody.add quote do:
    for `iterIndex` in 0 ..< `size`:
      yield `objConstr`

  let iterProc = nnkIteratorDef.newTree(
    postfix(iterProcName, "*"),
    newEmptyNode(),
    newEmptyNode(),
    nnkFormalParams.newTree(
      typ,
      nnkIdentDefs.newTree(paramTable, ident("ArrowTable"), newEmptyNode()),
      nnkIdentDefs.newTree(tag, typTag, newEmptyNode())
    ),
    nnkPragma.newTree(ident("inline")),
    newEmptyNode(),
    iterBody
  )

  result.add typSection
  result.add newbuilderProc
  result.add addProc
  result.add buildProc
  result.add schemaProc
  result.add iterProc

template newTypedBuilder*(T: typedesc): TypedBuilder[T] =
  newTypedBuilder(TypeTag[T]())

template iter*(tbl: ArrowTable, T: typedesc): untyped =
  ## Iterate over the ArrowTable, converting rows into the type `T`.
  iter(tbl, TypeTag[T]())