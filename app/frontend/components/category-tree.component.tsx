import React, { useState } from "react";
import TreeView, {
  INode,
  ITreeViewOnExpandProps,
  ITreeViewOnLoadDataProps,
  ITreeViewOnNodeSelectProps,
  NodeId,
  flattenTree,
} from "react-accessible-treeview";
import { AiOutlineLoading } from "react-icons/ai";
import { CategoryNode } from "../types/search-tool.type";
import { IFlatMetadata } from "react-accessible-treeview/dist/TreeView/utils";
import { fetchSubcatsAndPages } from "../services/articles.service";
import { convertResponseToTree } from "../utils/search-utils";
import SelectedNodesDisplay from "./selected-nodes-display.component";
import toast from "react-hot-toast";
import { BsExclamationCircleFill } from "react-icons/bs";
import { ArrowIcon, CheckBoxIcon } from "./tree-icons.component";

export default function CategoryTree({
  treeData,
  languageCode,
  categoryName,
}: {
  treeData: CategoryNode;
  languageCode: string;
  categoryName: string;
}) {
  const [categoryTree, setCategoryTree] = useState<INode<IFlatMetadata>[]>(
    flattenTree(treeData)
  );
  const [nodesAlreadyLoaded, setNodesAlreadyLoaded] = useState<
    INode<IFlatMetadata>[]
  >([]);
  const [manuallySelectedNodes, setManuallySelectedNodes] = useState<
    Map<NodeId, INode<IFlatMetadata>>
  >(new Map());

  const DEPTH_LIMIT: number = 1;
  const updateTreeData = (
    currentTree: INode<IFlatMetadata>[],
    id: NodeId,
    children: INode<IFlatMetadata>[]
  ) => {
    const data = currentTree.map((node) => {
      if (node.id === id && node.children.length === 0) {
        node.children = children.map((el) => {
          return el.id;
        });
      }
      return node;
    });

    // only add children if they are not already in the tree
    for (const child of children) {
      if (!data.find((el) => el.id === child.id)) {
        data.push(child);
      }
    }

    return data;
  };

  const fetchChildrenRecursively = async (
    node: INode<IFlatMetadata>,
    depth: number = 0
  ) => {
    if (depth > DEPTH_LIMIT && node.isBranch) {
      return [];
    }
    const fetchedSubcatsAndPages = await fetchSubcatsAndPages(
      node.id,
      languageCode,
      true
    );
    if (!fetchedSubcatsAndPages) {
      toast.error("Failed to fetch subcategories");
      return [];
    }
    const parsedData = convertResponseToTree(fetchedSubcatsAndPages, node);
    for (const childNode of parsedData) {
      const fetchedChildren = await fetchChildrenRecursively(
        childNode,
        depth + 1
      );

      if (!childNode.isBranch) {
        continue;
      }

      setCategoryTree((value) => {
        return updateTreeData(value, childNode.id, fetchedChildren);
      });
      childNode.children = fetchedChildren.map((child) => child.id);
    }
    return parsedData;
  };
  const onLoadData = async (loadProps: ITreeViewOnLoadDataProps) => {
    const element = loadProps.element;
    if (element.children.length > 0) {
      return;
    }

    const fetchedData = await fetchChildrenRecursively(element);
    return new Promise<void>((resolve) => {
      if (element.children.length > 0) {
        resolve();
        return;
      }
      setCategoryTree((value) => {
        return updateTreeData(value, element.id, fetchedData);
      });

      resolve();
    });
  };

  const handleNodeSelect = async (selectProps: ITreeViewOnNodeSelectProps) => {
    if (
      selectProps.isSelected &&
      !selectProps.element.isBranch &&
      !nodesAlreadyLoaded.includes(selectProps.element) &&
      selectProps.element?.parent === 1 // This is the hardcoded id for the top-level parent node
    ) {
      const fetchedSubcatsAndPages = await fetchSubcatsAndPages(
        selectProps.element.id,
        languageCode,
        true
      );
      if (!fetchedSubcatsAndPages) {
        toast.error("Failed to fetch subcategories");
        return [];
      }
      convertResponseToTree(fetchedSubcatsAndPages, selectProps.element);
      setNodesAlreadyLoaded([...nodesAlreadyLoaded, selectProps.element]);
    }
    selectProps.isSelected &&
      setManuallySelectedNodes((prevSelectedMap) =>
        new Map(prevSelectedMap).set(
          selectProps.element.id,
          selectProps.element
        )
      );
    !selectProps.isSelected &&
      setManuallySelectedNodes((prevSelectedMap) => {
        const newMap = new Map(prevSelectedMap);
        newMap.delete(selectProps.element.id);
        return newMap;
      });
  };

  const wrappedOnLoadData = async (loadProps: ITreeViewOnLoadDataProps) => {
    const nodeHasNoChildData = loadProps.element.children.length === 0;
    const nodeHasAlreadyBeenLoaded = nodesAlreadyLoaded.find(
      (e) => e.id === loadProps.element.id
    );

    if (!nodeHasAlreadyBeenLoaded) {
      await onLoadData(loadProps);
    }

    if (nodeHasNoChildData && !nodeHasAlreadyBeenLoaded) {
      setNodesAlreadyLoaded([...nodesAlreadyLoaded, loadProps.element]);
    }
  };

  const handleExpand = (expandProps: ITreeViewOnExpandProps) => {};

  // This function checks for any unselected children that may belong to a parent node
  // This is used as a flag to display to the user whether or not there are unfetched/unselected child nodes further down the tree
  const hasUnselectedChildNodes = (element: INode<IFlatMetadata>) => {
    return element.children.some((childNodeId) => {
      const childNode = manuallySelectedNodes.get(childNodeId);
      return childNode?.isBranch && childNode.children.length === 0;
    });
  };

  return (
    <div className="TreeContainer">
      <div className="checkbox">
        <TreeView
          data={categoryTree}
          aria-label="Checkbox tree"
          multiSelect
          propagateSelect
          togglableSelect
          onLoadData={wrappedOnLoadData}
          onSelect={handleNodeSelect}
          onExpand={handleExpand}
          nodeRenderer={({
            element,
            isBranch,
            isExpanded,
            isSelected,
            isDisabled,
            isHalfSelected,
            getNodeProps,
            level,
            handleSelect,
            handleExpand,
          }) => {
            isDisabled = !!(element.isBranch && element.children.length === 0);
            const branchNode = (
              isExpanded: boolean,
              element: INode<IFlatMetadata>
            ) => {
              return isExpanded && element.children.length === 0 ? (
                <AiOutlineLoading className="loading-icon" />
              ) : (
                <ArrowIcon isOpen={isExpanded} />
              );
            };
            return (
              <div
                {...getNodeProps({ onClick: handleExpand })}
                style={{
                  marginLeft: 40 * (level - 1),
                }}
              >
                {isBranch && branchNode(isExpanded, element)}
                <CheckBoxIcon
                  onClick={(e) => {
                    if (!isDisabled) {
                      handleSelect(e);
                    }
                    e.stopPropagation();
                  }}
                  variant={
                    isDisabled
                      ? "disabled"
                      : isHalfSelected
                      ? "some"
                      : isSelected
                      ? "all"
                      : "none"
                  }
                />
                <span
                  className="name"
                  style={{ opacity: isDisabled ? 0.5 : 1 }}
                >
                  {element.name}
                </span>
                {isSelected && hasUnselectedChildNodes(element) ? (
                  <span
                    data-title={
                      "This category is missing certain subcategories at a lower depth"
                    }
                  >
                    <BsExclamationCircleFill
                      color="#71afef"
                      style={{
                        verticalAlign: "middle",
                        marginLeft: 5,
                        marginBottom: 5,
                      }}
                    />
                  </span>
                ) : (
                  ""
                )}
              </div>
            );
          }}
        />
      </div>
      <SelectedNodesDisplay
        categoryName={categoryName}
        selectedNodes={manuallySelectedNodes}
      />
    </div>
  );
}
